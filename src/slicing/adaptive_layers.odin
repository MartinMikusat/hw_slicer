package slicing

import "core:math"

import contracts "../contracts"
import geometry "../geometry"

Adaptive_Layer_Config :: struct {
	request_hash:       contracts.Content_Hash,
	first_layer_height: contracts.Micrometres,
	min_layer_height:   contracts.Micrometres,
	max_layer_height:   contracts.Micrometres,
	nominal_height:     contracts.Micrometres,
	max_layer_count:    u32,
	smooth_passes:      int, // default 3
}

// Builds a curvature/slope-driven variable layer height schedule from triangle normals.
// Shallow slopes (0.05 < |nz| < 0.98) receive finer layers down to `min_layer_height`;
// vertical walls receive taller layers up to `max_layer_height`.
adaptive_layer_schedule_build :: proc(
	mesh: geometry.Canonical_Mesh,
	config: Adaptive_Layer_Config,
	allocator := context.allocator,
) -> (Fixed_Layer_Schedule, Schedule_Error) {
	if len(mesh.triangle_ids) == 0 || len(mesh.vertex_z) == 0 {
		return {}, .Invalid_Bounds
	}
	min_h := f64(i64(config.min_layer_height))
	max_h := f64(i64(config.max_layer_height))
	nom_h := f64(i64(config.nominal_height))
	first_h := i64(config.first_layer_height)
	if first_h <= 0 || min_h <= 0 || max_h < min_h || nom_h <= 0 {
		return {}, .Invalid_Layer_Step
	}

	min_z_mm := mesh.vertex_z[0]
	max_z_mm := mesh.vertex_z[0]
	for z in mesh.vertex_z[1:] {
		if z < min_z_mm {min_z_mm = z}
		if z > max_z_mm {max_z_mm = z}
	}
	min_z_um := i64(math.floor(min_z_mm * 1000.0))
	max_z_um := i64(math.ceil(max_z_mm * 1000.0))
	if max_z_um <= min_z_um {return {}, .Invalid_Bounds}

	// Bucket maximum slope |nz| in 50 um vertical bins.
	bin_um :: 50.0
	span_um := f64(max_z_um - min_z_um)
	bin_count := max(1, int(math.ceil(span_um / bin_um)))
	if bin_count > 200_000 {bin_count = 200_000}

	bin_max_nz := make([]f64, bin_count, context.temp_allocator)
	for ti in 0..<len(mesh.triangle_ids) {
		ia := mesh.triangle_a[ti]
		ib := mesh.triangle_b[ti]
		ic := mesh.triangle_c[ti]
		ax, ay, az := mesh.vertex_x[ia], mesh.vertex_y[ia], mesh.vertex_z[ia]
		bx, by, bz := mesh.vertex_x[ib], mesh.vertex_y[ib], mesh.vertex_z[ib]
		cx, cy, cz := mesh.vertex_x[ic], mesh.vertex_y[ic], mesh.vertex_z[ic]

		ux, uy, uz := bx - ax, by - ay, bz - az
		vx, vy, vz := cx - ax, cy - ay, cz - az
		nx := uy*vz - uz*vy
		ny := uz*vx - ux*vz
		nz := ux*vy - uy*vx
		nlen := math.sqrt(nx*nx + ny*ny + nz*nz)
		if nlen < 1e-9 {continue}
		abs_nz := math.abs(nz) / nlen
		// Ignore nearly flat horizontal surfaces (handled by top/bottom skins) and purely vertical walls.
		if abs_nz < 0.05 || abs_nz > 0.985 {continue}

		tz_min := min(az, min(bz, cz)) * 1000.0 - f64(min_z_um)
		tz_max := max(az, max(bz, cz)) * 1000.0 - f64(min_z_um)
		b0 := clamp(int(math.floor(tz_min / bin_um)), 0, bin_count - 1)
		b1 := clamp(int(math.ceil(tz_max / bin_um)), 0, bin_count - 1)
		for b in b0..=b1 {
			if abs_nz > bin_max_nz[b] {
				bin_max_nz[b] = abs_nz
			}
		}
	}

	// Convert per-bin slope into target layer height and smooth transitions.
	bin_h := make([]f64, bin_count, context.temp_allocator)
	for b in 0..<bin_count {
		if bin_max_nz[b] <= 0.05 {
			bin_h[b] = max_h
		} else {
			// Higher |nz| (shallower slope) -> finer layer height toward min_h.
			t := clamp((bin_max_nz[b] - 0.05) / 0.90, 0.0, 1.0)
			bin_h[b] = max_h - t*(max_h - min_h)
		}
	}
	passes := config.smooth_passes if config.smooth_passes > 0 else 3
	tmp_h := make([]f64, bin_count, context.temp_allocator)
	for _ in 0..<passes {
		for b in 0..<bin_count {
			l := bin_h[max(0, b - 1)]
			c := bin_h[b]
			r := bin_h[min(bin_count - 1, b + 1)]
			tmp_h[b] = 0.25*l + 0.5*c + 0.25*r
		}
		copy(bin_h, tmp_h)
	}

	// Walk layer tops from the first layer upward using the smoothed target height (quantized to
	// 10 um). Each layer is sectioned at its mid-height and exists while that plane lies below
	// the model top.
	z_list := make([dynamic]contracts.Micrometres, 0, 512, allocator)
	top_list := make([dynamic]contracts.Micrometres, 0, 512, allocator)
	cleanup :: proc(a, b: ^[dynamic]contracts.Micrometres) {
		delete(a^)
		delete(b^)
	}
	if min_z_um + first_h/2 >= max_z_um {
		cleanup(&z_list, &top_list)
		return {}, .Invalid_Bounds
	}
	cur_top := min_z_um + first_h
	append(&z_list, contracts.Micrometres(min_z_um + first_h/2))
	append(&top_list, contracts.Micrometres(cur_top))

	for {
		if u32(len(z_list)) >= config.max_layer_count {
			cleanup(&z_list, &top_list)
			return {}, .Layer_Limit
		}
		// Take the finest target height over the whole span the new layer would cover, so a
		// coarse layer does not step over the start of a shallow-slope region.
		b0 := clamp(int(f64(cur_top - min_z_um) / bin_um), 0, bin_count - 1)
		target := bin_h[b0]
		b1 := clamp(int(f64(cur_top + i64(math.ceil(target)) - min_z_um) / bin_um), 0, bin_count - 1)
		for b in b0..=b1 {target = min(target, bin_h[b])}
		step := i64(math.round(target / 10.0)) * 10
		if step < i64(min_h) {step = i64(min_h)}
		if step > i64(max_h) {step = i64(max_h)}
		if step < 10 {step = 10}
		next_top := cur_top + step
		section := next_top - step/2
		if section >= max_z_um {break}
		append(&z_list, contracts.Micrometres(section))
		append(&top_list, contracts.Micrometres(next_top))
		cur_top = next_top
	}

	layer_ids := make([]contracts.Stable_ID, len(z_list), allocator)
	if layer_ids == nil {
		cleanup(&z_list, &top_list)
		return {}, .Allocation_Failed
	}
	root_id := contracts.stable_id_root(config.request_hash, .Layer)
	for i in 0..<len(z_list) {
		layer_ids[i] = contracts.stable_id_child(root_id, .Layer, u64(i))
	}

	return Fixed_Layer_Schedule{
		request_hash  = config.request_hash,
		minimum_z     = contracts.Micrometres(min_z_um),
		maximum_z     = contracts.Micrometres(max_z_um),
		first_plane_z = z_list[0],
		first_layer_height = config.first_layer_height,
		layer_step    = config.nominal_height,
		adaptive      = true,
		layer_z       = z_list[:],
		print_z       = top_list[:],
		layer_ids     = layer_ids,
	}, .None
}
