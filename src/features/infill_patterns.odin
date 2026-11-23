package features

import "core:math"
import "core:slice"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"
import slicing "../slicing"

Infill_Pattern :: enum u8 {
	Rectilinear,
	Grid,
	Triangles,
	Gyroid,
	Cubic,
	Honeycomb,
	Lightning,
}

Infill_Pattern_Config :: struct {
	pattern:        Infill_Pattern,
	spacing_um:     contracts.Micrometres,
	line_width_um:  contracts.Micrometres,
	boundary_inset: contracts.Micrometres,
}

Infill_Pattern_Path :: struct {
	layer_index: u32,
	points:      []polygon.Polygon_Point,
	line_widths: []contracts.Micrometres,
}

Infill_Pattern_Result :: struct {
	paths: []Infill_Pattern_Path,
}

infill_pattern_result_destroy :: proc(r: ^Infill_Pattern_Result, allocator := context.allocator) {
	for p in r.paths {
		delete(p.points, allocator)
		delete(p.line_widths, allocator)
	}
	delete(r.paths, allocator)
	r^ = {}
}

// Generates sparse infill polylines for Grid, Triangles, Gyroid, Cubic, Honeycomb, and Lightning
// patterns, clipped to each region's inset boundary.
infill_pattern_generate :: proc(
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	skins: Skin_Result,
	layer_z: []contracts.Micrometres,
	provider: polygon.Polygon_Provider,
	config: Infill_Pattern_Config,
	allocator := context.allocator,
) -> Infill_Pattern_Result {
	if provider.offset == nil || i64(config.spacing_um) <= 0 || i64(config.line_width_um) <= 0 {
		return {}
	}
	layer_count := len(regions.layers)
	if layer_count == 0 {return {}}

	out := make([dynamic]Infill_Pattern_Path, 0, 256, allocator)

	// For Lightning infill, precompute which XY bounding cells are beneath top-skin regions
	// by propagating top-skin footprints downward with a 45-degree cone.
	lightning_boxes: [][4]i64
	has_lightning := make([]bool, layer_count, allocator)
	defer delete(has_lightning, allocator)
	if config.pattern == .Lightning {
		lightning_boxes = make([][4]i64, layer_count, allocator)
		for li in 0..<layer_count {
			lightning_boxes[li] = {max(i64), max(i64), min(i64), min(i64)}
		}
		for mask in skins.masks {
			if mask.kind != .Top && mask.kind != .Top_Bottom {continue}
			if int(mask.layer_index) >= layer_count || mask.path_count == 0 {continue}
			p_start := int(mask.path_offset)
			p_end := p_start + int(mask.path_count)
			for p in skins.paths[p_start:p_end] {
				pt_start := int(p.point_offset)
				pt_end := pt_start + int(p.point_count)
				for pt in skins.points[pt_start:pt_end] {
					b := &lightning_boxes[mask.layer_index]
					b[0] = min(b[0], i64(pt.x))
					b[1] = min(b[1], i64(pt.y))
					b[2] = max(b[2], i64(pt.x))
					b[3] = max(b[3], i64(pt.y))
					has_lightning[mask.layer_index] = true
				}
			}
		}
		// Propagate top-skin support cones downward at 45 degrees (shrink cone toward center as Z drops).
		for li := layer_count - 2; li >= 0; li -= 1 {
			if !has_lightning[li + 1] {continue}
			dz := i64(layer_z[li + 1]) - i64(layer_z[li])
			if dz < 0 {dz = 200}
			above := lightning_boxes[li + 1]
			if !has_lightning[li] {
				lightning_boxes[li] = {above[0] - dz, above[1] - dz, above[2] + dz, above[3] + dz}
				has_lightning[li] = true
			} else {
				b := &lightning_boxes[li]
				b[0] = min(b[0], above[0] - dz)
				b[1] = min(b[1], above[1] - dz)
				b[2] = max(b[2], above[2] + dz)
				b[3] = max(b[3], above[3] + dz)
			}
		}
	}
	defer delete(lightning_boxes, allocator)

	S := f64(i64(config.spacing_um))
	lw := config.line_width_um

	for layer, li in regions.layers {
		if layer.region_count == 0 {continue}
		if config.pattern == .Lightning && !has_lightning[li] {continue}
		z_f := f64(i64(layer_z[li])) if li < len(layer_z) else f64(li) * 200.0

		reg_start := int(layer.region_offset)
		reg_end := reg_start + int(layer.region_count)
		for ri in reg_start..<reg_end {
			input, in_err := perimeter_region_input(topology, regions, u32(ri), allocator)
			if in_err != .None {continue}
			boundary, off_err := provider.offset(
				input,
				-config.boundary_inset,
				.Miter,
				2.0,
				0.0,
				polygon.DEFAULT_POLYGON_LIMITS,
				allocator,
			)
			polygon.polygon_set_destroy(&input, allocator)
			if off_err != .None || len(boundary.paths) == 0 {
				polygon.polygon_set_destroy(&boundary, allocator)
				continue
			}

			min_x, min_y, max_x, max_y := infill_pat_bounds(boundary)
			if max_x <= min_x || max_y <= min_y {
				polygon.polygon_set_destroy(&boundary, allocator)
				continue
			}

			switch config.pattern {
			case .Rectilinear:
				// Handled by infill_generate; fallback to 0/90 alternating here if called directly.
				ang := 0.0 if (li % 2 == 0) else math.PI * 0.5
				infill_pat_hatch(&out, boundary, u32(li), min_x, min_y, max_x, max_y, ang, S, 0.0, lw, allocator)

			case .Grid:
				infill_pat_hatch(&out, boundary, u32(li), min_x, min_y, max_x, max_y, 0.0, S * 2.0, 0.0, lw, allocator)
				infill_pat_hatch(&out, boundary, u32(li), min_x, min_y, max_x, max_y, math.PI * 0.5, S * 2.0, 0.0, lw, allocator)

			case .Triangles:
				step := S * 3.0
				infill_pat_hatch(&out, boundary, u32(li), min_x, min_y, max_x, max_y, 0.0, step, 0.0, lw, allocator)
				infill_pat_hatch(&out, boundary, u32(li), min_x, min_y, max_x, max_y, math.PI / 3.0, step, 0.0, lw, allocator)
				infill_pat_hatch(&out, boundary, u32(li), min_x, min_y, max_x, max_y, 2.0 * math.PI / 3.0, step, 0.0, lw, allocator)

			case .Cubic:
				step := S * 3.0
				// 3D cubic lattice: phase shifts by z * tan(35.264 deg) ~= 0.70710678 * z.
				phase := z_f * 0.7071067811865476
				infill_pat_hatch(&out, boundary, u32(li), min_x, min_y, max_x, max_y, 0.0, step, phase, lw, allocator)
				infill_pat_hatch(&out, boundary, u32(li), min_x, min_y, max_x, max_y, math.PI / 3.0, step, phase, lw, allocator)
				infill_pat_hatch(&out, boundary, u32(li), min_x, min_y, max_x, max_y, 2.0 * math.PI / 3.0, step, phase, lw, allocator)

			case .Gyroid:
				infill_pat_gyroid(&out, boundary, u32(li), min_x, min_y, max_x, max_y, z_f, S, lw, allocator)

			case .Honeycomb:
				infill_pat_honeycomb(&out, boundary, u32(li), min_x, min_y, max_x, max_y, S, lw, allocator)

			case .Lightning:
				lb := lightning_boxes[li]
				c_min_x := max(min_x, lb[0])
				c_min_y := max(min_y, lb[1])
				c_max_x := min(max_x, lb[2])
				c_max_y := min(max_y, lb[3])
				if c_max_x > c_min_x && c_max_y > c_min_y {
					// Sparse branching ribs directly beneath top skin areas.
					ang := (math.PI * 0.25) if (li % 2 == 0) else (math.PI * 0.75)
					infill_pat_hatch(&out, boundary, u32(li), c_min_x, c_min_y, c_max_x, c_max_y, ang, S * 1.5, 0.0, lw, allocator)
				}
			}

			polygon.polygon_set_destroy(&boundary, allocator)
		}
	}

	return Infill_Pattern_Result{paths = out[:]}
}

@(private)
infill_pat_bounds :: proc(set: polygon.Polygon_Set) -> (min_x, min_y, max_x, max_y: i64) {
	if len(set.points) == 0 {return 0, 0, 0, 0}
	min_x, max_x = i64(set.points[0].x), i64(set.points[0].x)
	min_y, max_y = i64(set.points[0].y), i64(set.points[0].y)
	for pt in set.points {
		x, y := i64(pt.x), i64(pt.y)
		if x < min_x {min_x = x}
		if x > max_x {max_x = x}
		if y < min_y {min_y = y}
		if y > max_y {max_y = y}
	}
	return
}

// Clips a line family at angle `angle_rad` and perpendicular spacing `spacing` against `boundary`.
@(private)
infill_pat_hatch :: proc(
	out: ^[dynamic]Infill_Pattern_Path,
	boundary: polygon.Polygon_Set,
	layer_index: u32,
	min_x, min_y, max_x, max_y: i64,
	angle_rad: f64,
	spacing: f64,
	phase: f64,
	line_width: contracts.Micrometres,
	allocator := context.allocator,
) {
	if spacing <= 1.0 {return}
	dx := math.cos(angle_rad)
	dy := math.sin(angle_rad)
	nx := -dy
	ny := dx

	// Project AABB corners onto normal axis (nx, ny).
	corners := [4][2]f64{
		{f64(min_x), f64(min_y)},
		{f64(max_x), f64(min_y)},
		{f64(max_x), f64(max_y)},
		{f64(min_x), f64(max_y)},
	}
	n_min := corners[0][0]*nx + corners[0][1]*ny
	n_max := n_min
	for c in corners[1:] {
		v := c[0]*nx + c[1]*ny
		if v < n_min {n_min = v}
		if v > n_max {n_max = v}
	}

	k_start := i64(math.floor((n_min - phase) / spacing))
	k_end := i64(math.ceil((n_max - phase) / spacing))
	if k_end - k_start > 4096 {k_end = k_start + 4096}

	hits := make([dynamic]f64, 0, 32, context.temp_allocator)
	for k := k_start; k <= k_end; k += 1 {
		c_val := f64(k)*spacing + phase
		clear(&hits)
		for path in boundary.paths {
			start := int(path.offset)
			cnt := int(path.count)
			if cnt < 3 {continue}
			for ei in 0..<cnt {
				pa := boundary.points[start + ei]
				pb := boundary.points[start + (ei + 1) % cnt]
				da := f64(i64(pa.x))*nx + f64(i64(pa.y))*ny - c_val
				db := f64(i64(pb.x))*nx + f64(i64(pb.y))*ny - c_val
				if (da <= 0 && db > 0) || (db <= 0 && da > 0) {
					t := da / (da - db)
					ix := f64(i64(pa.x)) + t * f64(i64(pb.x) - i64(pa.x))
					iy := f64(i64(pa.y)) + t * f64(i64(pb.y) - i64(pa.y))
					append(&hits, ix*dx + iy*dy)
				}
			}
		}
		if len(hits) < 2 {continue}
		slice.sort(hits[:])
		for hi := 0; hi + 1 < len(hits); hi += 2 {
			t0 := hits[hi]
			t1 := hits[hi + 1]
			if t1 - t0 < 50.0 {continue}
			ax := contracts.Micrometres(i64(math.round(c_val*nx + t0*dx)))
			ay := contracts.Micrometres(i64(math.round(c_val*ny + t0*dy)))
			bx := contracts.Micrometres(i64(math.round(c_val*nx + t1*dx)))
			by := contracts.Micrometres(i64(math.round(c_val*ny + t1*dy)))
			if ax == bx && ay == by {continue}
			pts := make([]polygon.Polygon_Point, 2, allocator)
			pts[0] = {x = ax, y = ay}
			pts[1] = {x = bx, y = by}
			ws := make([]contracts.Micrometres, 2, allocator)
			ws[0] = line_width
			ws[1] = line_width
			append(out, Infill_Pattern_Path{layer_index = layer_index, points = pts, line_widths = ws})
		}
	}
}

// Clips a polyline against `boundary` by sampling segments and emitting contiguous interior runs.
@(private)
infill_pat_emit_clipped_polyline :: proc(
	out: ^[dynamic]Infill_Pattern_Path,
	boundary: polygon.Polygon_Set,
	layer_index: u32,
	raw_pts: []polygon.Polygon_Point,
	line_width: contracts.Micrometres,
	allocator := context.allocator,
) {
	if len(raw_pts) < 2 {return}
	run := make([dynamic]polygon.Polygon_Point, 0, len(raw_pts), context.temp_allocator)
	for i in 0..<len(raw_pts)-1 {
		a := raw_pts[i]
		b := raw_pts[i + 1]
		if a == b {continue}
		inside := bridge_polygon_contains_twice(boundary, i64(a.x) + i64(b.x), i64(a.y) + i64(b.y))
		if inside {
			if len(run) == 0 {
				append(&run, a)
			}
			if run[len(run)-1] != b {
				append(&run, b)
			}
		} else if len(run) >= 2 {
			infill_pat_flush_run(out, layer_index, run[:], line_width, allocator)
			clear(&run)
		} else {
			clear(&run)
		}
	}
	if len(run) >= 2 {
		infill_pat_flush_run(out, layer_index, run[:], line_width, allocator)
	}
}

@(private)
infill_pat_flush_run :: proc(
	out: ^[dynamic]Infill_Pattern_Path,
	layer_index: u32,
	run: []polygon.Polygon_Point,
	line_width: contracts.Micrometres,
	allocator := context.allocator,
) {
	if len(run) < 2 {return}
	pts := make([]polygon.Polygon_Point, len(run), allocator)
	ws := make([]contracts.Micrometres, len(run), allocator)
	copy(pts, run)
	for i in 0..<len(ws) {ws[i] = line_width}
	append(out, Infill_Pattern_Path{layer_index = layer_index, points = pts, line_widths = ws})
}

// Gyroid sinusoidal wave infill alternating X/Y across layers with smooth Z phase progression.
@(private)
infill_pat_gyroid :: proc(
	out: ^[dynamic]Infill_Pattern_Path,
	boundary: polygon.Polygon_Set,
	layer_index: u32,
	min_x, min_y, max_x, max_y: i64,
	z_um: f64,
	spacing: f64,
	line_width: contracts.Micrometres,
	allocator := context.allocator,
) {
	period := max(spacing * 2.0, 2000.0)
	amp := spacing * 0.42
	z_phase := (2.0 * math.PI * z_um) / period
	step := max(period / 12.0, 400.0)
	horizontal := (layer_index % 2) == 0

	raw := make([dynamic]polygon.Polygon_Point, 0, 128, context.temp_allocator)
	if horizontal {
		y0 := math.floor(f64(min_y)/spacing) * spacing
		for y := y0; y <= f64(max_y) + spacing; y += spacing {
			clear(&raw)
			row_phase := z_phase + (math.PI if (i64(math.round(y/spacing)) % 2 != 0) else 0.0)
			for x := f64(min_x); x <= f64(max_x) + step; x += step {
				cx := min(x, f64(max_x))
				cy := y + amp * math.sin((2.0 * math.PI * cx)/period + row_phase)
				append(&raw, polygon.Polygon_Point{
					x = contracts.Micrometres(i64(math.round(cx))),
					y = contracts.Micrometres(i64(math.round(cy))),
				})
				if cx >= f64(max_x) {break}
			}
			infill_pat_emit_clipped_polyline(out, boundary, layer_index, raw[:], line_width, allocator)
		}
	} else {
		x0 := math.floor(f64(min_x)/spacing) * spacing
		for x := x0; x <= f64(max_x) + spacing; x += spacing {
			clear(&raw)
			col_phase := z_phase + (math.PI if (i64(math.round(x/spacing)) % 2 != 0) else 0.0)
			for y := f64(min_y); y <= f64(max_y) + step; y += step {
				cy := min(y, f64(max_y))
				cx := x + amp * math.sin((2.0 * math.PI * cy)/period + col_phase)
				append(&raw, polygon.Polygon_Point{
					x = contracts.Micrometres(i64(math.round(cx))),
					y = contracts.Micrometres(i64(math.round(cy))),
				})
				if cy >= f64(max_y) {break}
			}
			infill_pat_emit_clipped_polyline(out, boundary, layer_index, raw[:], line_width, allocator)
		}
	}
}

// Regular hexagonal honeycomb zig-zag polylines clipped to boundary.
@(private)
infill_pat_honeycomb :: proc(
	out: ^[dynamic]Infill_Pattern_Path,
	boundary: polygon.Polygon_Set,
	layer_index: u32,
	min_x, min_y, max_x, max_y: i64,
	spacing: f64,
	line_width: contracts.Micrometres,
	allocator := context.allocator,
) {
	// Hex side length L such that cell height sqrt(3)*L ~= spacing * 1.5.
	side := max(spacing * 0.8660254, 800.0)
	h_half := side * 0.8660254037844386
	row_step := h_half * 2.0
	col_step := side * 3.0

	raw := make([dynamic]polygon.Polygon_Point, 0, 128, context.temp_allocator)
	row_start := i64(math.floor(f64(min_y) / row_step)) - 1
	row_end := i64(math.ceil(f64(max_y) / row_step)) + 1
	col_start := i64(math.floor(f64(min_x) / col_step)) - 1
	col_end := i64(math.ceil(f64(max_x) / col_step)) + 1

	for row := row_start; row <= row_end; row += 1 {
		base_y := f64(row) * row_step
		clear(&raw)
		for col := col_start; col <= col_end; col += 1 {
			bx := f64(col) * col_step
			// Upper zig-zag of hexagon row: (bx, y) -> (bx+side, y) -> (bx+1.5*side, y+h) -> (bx+2.5*side, y+h) -> (bx+3*side, y)
			pts_hex := [4][2]f64{
				{bx, base_y},
				{bx + side, base_y},
				{bx + 1.5*side, base_y + h_half},
				{bx + 2.5*side, base_y + h_half},
			}
			for p in pts_hex {
				append(&raw, polygon.Polygon_Point{
					x = contracts.Micrometres(i64(math.round(p[0]))),
					y = contracts.Micrometres(i64(math.round(p[1]))),
				})
			}
		}
		infill_pat_emit_clipped_polyline(out, boundary, layer_index, raw[:], line_width, allocator)
	}
}
