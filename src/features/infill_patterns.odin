package features

import "core:math"
import "core:mem"
import "core:slice"
import "core:sync"
import "core:thread"

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
	worker_threads: int, // <= 1 = single-core; > 1 = multi-core CPU threads
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
	exclude: []polygon.Polygon_Set = nil, // per layer: solid areas that sparse infill must not fill
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

	per_layer_out := make([][dynamic]Infill_Pattern_Path, layer_count, allocator)
	defer delete(per_layer_out, allocator)

	Infill_Worker_Ctx :: struct {
		topology:        slicing.Topology_Result,
		regions:         slicing.Region_Result,
		layer_z:         []contracts.Micrometres,
		provider:        polygon.Polygon_Provider,
		config:          Infill_Pattern_Config,
		exclude:         []polygon.Polygon_Set,
		lightning_boxes: [][4]i64,
		has_lightning:   []bool,
		S:               f64,
		lw:              contracts.Micrometres,
		per_layer_out:   [][dynamic]Infill_Pattern_Path,
		out_allocator:   mem.Allocator,
		next_layer:      int,
		layer_count:     int,
	}

	wctx := Infill_Worker_Ctx{
		topology        = topology,
		regions         = regions,
		layer_z         = layer_z,
		provider        = provider,
		config          = config,
		exclude         = exclude,
		lightning_boxes = lightning_boxes,
		has_lightning   = has_lightning,
		S               = S,
		lw              = lw,
		per_layer_out   = per_layer_out,
		out_allocator   = allocator,
		next_layer      = 0,
		layer_count     = layer_count,
	}

	worker_proc :: proc(c: ^Infill_Worker_Ctx) {
		for {
			li := sync.atomic_add(&c.next_layer, 1)
			if li >= c.layer_count {break}
			layer := c.regions.layers[li]
			if layer.region_count == 0 {continue}
			if c.config.pattern == .Lightning && !c.has_lightning[li] {continue}
			z_f := f64(i64(c.layer_z[li])) if li < len(c.layer_z) else f64(li) * 200.0

			local_out := make([dynamic]Infill_Pattern_Path, 0, 32, c.out_allocator)
			reg_start := int(layer.region_offset)
			reg_end := reg_start + int(layer.region_count)
			for ri in reg_start..<reg_end {
				input, in_err := perimeter_region_input(c.topology, c.regions, u32(ri), c.out_allocator)
				if in_err != .None {continue}
				boundary, off_err := c.provider.offset(
					input,
					-c.config.boundary_inset,
					.Miter,
					2.0,
					0.0,
					polygon.DEFAULT_POLYGON_LIMITS,
					c.out_allocator,
				)
				polygon.polygon_set_destroy(&input, c.out_allocator)
				if off_err != .None || len(boundary.paths) == 0 {
					polygon.polygon_set_destroy(&boundary, c.out_allocator)
					continue
				}
				if li < len(c.exclude) && len(c.exclude[li].paths) > 0 {
					sparse, diff_err := c.provider.boolean(
						boundary,
						c.exclude[li],
						.Difference,
						.Non_Zero,
						polygon.DEFAULT_POLYGON_LIMITS,
						c.out_allocator,
					)
					polygon.polygon_set_destroy(&boundary, c.out_allocator)
					if diff_err != .None || len(sparse.paths) == 0 {
						polygon.polygon_set_destroy(&sparse, c.out_allocator)
						continue
					}
					boundary = sparse
				}

				min_x, min_y, max_x, max_y := infill_pat_bounds(boundary)
				if max_x <= min_x || max_y <= min_y {
					polygon.polygon_set_destroy(&boundary, c.out_allocator)
					continue
				}

				switch c.config.pattern {
				case .Rectilinear:
					ang := 0.0 if (li % 2 == 0) else math.PI * 0.5
					infill_pat_hatch(&local_out, boundary, u32(li), min_x, min_y, max_x, max_y, ang, c.S, 0.0, c.lw, c.out_allocator)
				case .Grid:
					infill_pat_hatch(&local_out, boundary, u32(li), min_x, min_y, max_x, max_y, 0.0, c.S * 2.0, 0.0, c.lw, c.out_allocator)
					infill_pat_hatch(&local_out, boundary, u32(li), min_x, min_y, max_x, max_y, math.PI * 0.5, c.S * 2.0, 0.0, c.lw, c.out_allocator)
				case .Triangles:
					step := c.S * 3.0
					infill_pat_hatch(&local_out, boundary, u32(li), min_x, min_y, max_x, max_y, 0.0, step, 0.0, c.lw, c.out_allocator)
					infill_pat_hatch(&local_out, boundary, u32(li), min_x, min_y, max_x, max_y, math.PI / 3.0, step, 0.0, c.lw, c.out_allocator)
					infill_pat_hatch(&local_out, boundary, u32(li), min_x, min_y, max_x, max_y, 2.0 * math.PI / 3.0, step, 0.0, c.lw, c.out_allocator)
				case .Cubic:
					step := c.S * 3.0
					phase := z_f * 0.7071067811865476
					infill_pat_hatch(&local_out, boundary, u32(li), min_x, min_y, max_x, max_y, 0.0, step, phase, c.lw, c.out_allocator)
					infill_pat_hatch(&local_out, boundary, u32(li), min_x, min_y, max_x, max_y, math.PI / 3.0, step, phase, c.lw, c.out_allocator)
					infill_pat_hatch(&local_out, boundary, u32(li), min_x, min_y, max_x, max_y, 2.0 * math.PI / 3.0, step, phase, c.lw, c.out_allocator)
				case .Gyroid:
					infill_pat_gyroid(&local_out, boundary, u32(li), min_x, min_y, max_x, max_y, z_f, c.S, c.lw, c.out_allocator)
				case .Honeycomb:
					infill_pat_honeycomb(&local_out, boundary, u32(li), min_x, min_y, max_x, max_y, c.S, c.lw, c.out_allocator)
				case .Lightning:
					lb := c.lightning_boxes[li]
					c_min_x := max(min_x, lb[0])
					c_min_y := max(min_y, lb[1])
					c_max_x := min(max_x, lb[2])
					c_max_y := min(max_y, lb[3])
					if c_max_x > c_min_x && c_max_y > c_min_y {
						ang := (math.PI * 0.25) if (li % 2 == 0) else (math.PI * 0.75)
						infill_pat_hatch(&local_out, boundary, u32(li), c_min_x, c_min_y, c_max_x, c_max_y, ang, c.S * 1.5, 0.0, c.lw, c.out_allocator)
					}
				}
				polygon.polygon_set_destroy(&boundary, c.out_allocator)
			}
			c.per_layer_out[li] = local_out
		}
	}

	num_workers := clamp(config.worker_threads, 1, 16)
	if layer_count < 16 || num_workers <= 1 {
		worker_proc(&wctx)
	} else {
		threads: [15]^thread.Thread
		spawn_count := num_workers - 1
		for wi in 0..<spawn_count {
			threads[wi] = thread.create_and_start_with_poly_data(&wctx, worker_proc)
		}
		worker_proc(&wctx)
		for wi in 0..<spawn_count {
			if threads[wi] != nil {
				thread.join(threads[wi])
				thread.destroy(threads[wi])
			}
		}
	}

	for li in 0..<layer_count {
		for p in per_layer_out[li] {
			append(&out, p)
		}
		delete(per_layer_out[li])
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

// Band-filtered edge representation for O(band_edges) point-in-polygon tests along a gyroid wave.
@(private = "file")
Band_Edge_2 :: struct {
	ax2, ay2, bx2, by2: i64,
}

@(private = "file")
band_edges_contains_twice :: proc(edges: []Band_Edge_2, qx, qy: i64) -> bool {
	inside := false
	for e in edges {
		lo_y := min(e.ay2, e.by2)
		hi_y := max(e.ay2, e.by2)
		if qy < lo_y || qy > hi_y {continue}
		dx := e.bx2 - e.ax2
		dy := e.by2 - e.ay2
		qdx := qx - e.ax2
		qdy := qy - e.ay2
		cross: i128
		if abs(dx) < 2_000_000_000 && abs(dy) < 2_000_000_000 &&
		   abs(qdx) < 2_000_000_000 && abs(qdy) < 2_000_000_000 {
			cross = i128(dx*qdy - dy*qdx)
		} else {
			cross = i128(dx)*i128(qdy) - i128(dy)*i128(qdx)
		}
		if cross == 0 && qx >= min(e.ax2, e.bx2) && qx <= max(e.ax2, e.bx2) {
			return true
		}
		if (e.ay2 <= qy && qy < e.by2) || (e.by2 <= qy && qy < e.ay2) {
			if (dy > 0 && cross < 0) || (dy < 0 && cross > 0) {
				inside = !inside
			}
		}
	}
	return inside
}

// Gyroid infill, ported from OrcaSlicer/PrusaSlicer `FillGyroid` (standard parametric path): the
// layer is a slice of the gyroid surface sin x cos y + sin y cos z + sin z cos x = 0, drawn as
// waves along x (or y, by layer Z) that are offset by pi in pattern units. One pattern unit is
// `spacing / GYROID_DENSITY_ADJUST` micrometres, where `spacing` is the straight-row spacing for
// the requested density. Waves are clipped exactly to the boundary. Orca uses 2.44 and also
// connects the lines along the boundary; without connections, 2.575 makes the deposited volume
// fraction equal the requested density (measured on a 40 mm cube at 15 %).
GYROID_DENSITY_ADJUST :: 2.575
GYROID_PATTERN_TOLERANCE_UM :: 200.0

@(private = "file")
gyroid_f :: proc(x, z_sin, z_cos: f64, vertical, flip: bool) -> f64 {
	if vertical {
		phase_offset := (math.PI if z_cos < 0 else 0.0) + math.PI
		a := math.sin(x + phase_offset)
		b := -z_cos
		res := z_sin * math.cos(x + phase_offset + (math.PI if flip else 0.0))
		r := math.sqrt(a*a + b*b)
		return math.asin(a/r) + math.asin(res/r) + math.PI
	}
	phase_offset := math.PI if z_sin < 0 else 0.0
	a := math.cos(x + phase_offset)
	b := -z_sin
	res := z_cos * math.sin(x + phase_offset + (0.0 if flip else math.PI))
	r := math.sqrt(a*a + b*b)
	return math.asin(a/r) + math.asin(res/r) + 0.5*math.PI
}

// One period [0, 2 pi] of the wave, refined until every midpoint is within `tolerance` (pattern
// units) of its chord.
@(private = "file")
gyroid_one_period :: proc(z_sin, z_cos: f64, vertical, flip: bool, tolerance: f64) -> [dynamic][2]f64 {
	pts := make([dynamic][2]f64, 0, 64, context.temp_allocator)
	for x := 0.0; x < 2.0*math.PI - 1e-9; x += 0.5*math.PI {
		append(&pts, [2]f64{x, gyroid_f(x, z_sin, z_cos, vertical, flip)})
	}
	append(&pts, [2]f64{2.0*math.PI, gyroid_f(2.0*math.PI, z_sin, z_cos, vertical, flip)})
	for pass in 0..<16 {
		size := len(pts)
		for i in 1..<size {
			lp, rp := pts[i - 1], pts[i]
			x := lp[0] + (rp[0] - lp[0]) / 2
			ip := [2]f64{x, gyroid_f(x, z_sin, z_cos, vertical, flip)}
			cross := (ip[0]-lp[0])*(ip[1]-rp[1]) - (ip[1]-lp[1])*(ip[0]-rp[0])
			if math.abs(cross) > tolerance*tolerance {append(&pts, ip)}
		}
		if len(pts) == size {break}
		slice.sort_by(pts[:], proc(a, b: [2]f64) -> bool {return a[0] < b[0]})
		_ = pass
	}
	return pts
}

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
	scale := spacing / GYROID_DENSITY_ADJUST // micrometres per pattern unit
	if scale <= 1.0 {return}
	flow_spacing := f64(i64(line_width))
	tolerance := min(flow_spacing / 2.0, GYROID_PATTERN_TOLERANCE_UM) / scale
	z := z_um / scale
	z_sin, z_cos := math.sin(z), math.cos(z)
	vertical := math.abs(z_sin) <= math.abs(z_cos)
	// Pattern-space range, waves running along the first coordinate.
	lo := [2]f64{f64(min_x) / scale, f64(min_y) / scale}
	hi := [2]f64{f64(max_x) / scale, f64(max_y) / scale}
	lower_bound := 0.0
	flip := true
	if vertical {
		flip = false
		lower_bound = -math.PI
		lo = {lo[1], lo[0]}
		hi = {hi[1], hi[0]}
	}
	odd := gyroid_one_period(z_sin, z_cos, vertical, flip, tolerance)
	even := gyroid_one_period(z_sin, z_cos, vertical, !flip, tolerance)
	f_min, f_max := max(f64), min(f64)
	for p in odd {f_min = min(f_min, p[1]); f_max = max(f_max, p[1])}
	for p in even {f_min = min(f_min, p[1]); f_max = max(f_max, p[1])}

	// Boundary edges in band coordinates (x along the wave, y across it), doubled.
	all_edges := make([dynamic]Band_Edge_2, 0, len(boundary.points), context.temp_allocator)
	for path in boundary.paths {
		n := int(path.count)
		if n < 3 {continue}
		s := int(path.offset)
		prev := boundary.points[s + n - 1]
		for ei in 0..<n {
			cur := boundary.points[s + ei]
			if vertical {
				append(&all_edges, Band_Edge_2{i64(prev.y)*2, i64(prev.x)*2, i64(cur.y)*2, i64(cur.x)*2})
			} else {
				append(&all_edges, Band_Edge_2{i64(prev.x)*2, i64(prev.y)*2, i64(cur.x)*2, i64(cur.y)*2})
			}
			prev = cur
		}
	}
	band := make([dynamic]Band_Edge_2, 0, 32, context.temp_allocator)
	wave := make([dynamic][2]f64, 0, 256, context.temp_allocator)
	run := make([dynamic]polygon.Polygon_Point, 0, 128, context.temp_allocator)
	cuts := make([dynamic]f64, 0, 8, context.temp_allocator)
	min_piece := 0.8 * flow_spacing

	first_i := i64(math.ceil((lo[1] - f_max - lower_bound) / math.PI))
	for i := first_i; lower_bound + f64(i)*math.PI + f_min <= hi[1]; i += 1 {
		one_period := odd if i % 2 == 0 else even
		offset := lower_bound + f64(i)*math.PI
		// Band of this wave, in doubled micrometres across the wave.
		band_lo := i64(math.floor((offset + f_min) * scale * 2.0)) - 4
		band_hi := i64(math.ceil((offset + f_max) * scale * 2.0)) + 4
		clear(&band)
		for e in all_edges {
			if max(e.ay2, e.by2) >= band_lo && min(e.ay2, e.by2) <= band_hi {append(&band, e)}
		}
		if len(band) == 0 {continue}
		// The wave in band coordinates (micrometres), covering [lo.x, hi.x].
		clear(&wave)
		period := 2.0 * math.PI
		n := len(one_period) - 1
		x0 := math.floor(lo[0] / period) * period
		k := 0
		for k + 1 < n && x0 + one_period[k + 1][0] <= lo[0] {k += 1}
		for {
			p := [2]f64{(x0 + one_period[k][0]) * scale, (one_period[k][1] + offset) * scale}
			append(&wave, p)
			if x0 + one_period[k][0] >= hi[0] {break}
			k += 1
			if k == n {
				k = 0
				x0 += period
			}
		}
		// Exact clip: split each segment where it crosses a band edge, keep inside pieces.
		clear(&run)
		piece_length := 0.0
		flush :: proc(out: ^[dynamic]Infill_Pattern_Path, layer_index: u32, run: ^[dynamic]polygon.Polygon_Point, length: ^f64, min_piece: f64, line_width: contracts.Micrometres, allocator: mem.Allocator) {
			if len(run) >= 2 && length^ >= min_piece {infill_pat_flush_run(out, layer_index, run[:], line_width, allocator)}
			clear(run)
			length^ = 0
		}
		to_point :: proc(p: [2]f64, vertical: bool) -> polygon.Polygon_Point {
			x, y := p[0], p[1]
			if vertical {x, y = y, x}
			return {x = contracts.Micrometres(i64(math.round(x))), y = contracts.Micrometres(i64(math.round(y)))}
		}
		for si in 0..<len(wave) - 1 {
			a, b := wave[si], wave[si + 1]
			clear(&cuts)
			append(&cuts, 0.0)
			dx, dy := b[0] - a[0], b[1] - a[1]
			for e in band {
				ex0, ey0 := f64(e.ax2) / 2, f64(e.ay2) / 2
				ex1, ey1 := f64(e.bx2) / 2, f64(e.by2) / 2
				fx, fy := ex1 - ex0, ey1 - ey0
				denom := dx*fy - dy*fx
				if denom == 0 {continue}
				t := ((ex0 - a[0])*fy - (ey0 - a[1])*fx) / denom
				u := ((ex0 - a[0])*dy - (ey0 - a[1])*dx) / denom
				if t > 0 && t < 1 && u >= 0 && u <= 1 {append(&cuts, t)}
			}
			append(&cuts, 1.0)
			if len(cuts) > 3 {slice.sort(cuts[1:len(cuts) - 1])}
			for ci in 0..<len(cuts) - 1 {
				t0, t1 := cuts[ci], cuts[ci + 1]
				if t1 - t0 <= 1e-9 {continue}
				p0 := [2]f64{a[0] + dx*t0, a[1] + dy*t0}
				p1 := [2]f64{a[0] + dx*t1, a[1] + dy*t1}
				mid_x2 := i64(math.round(p0[0] + p1[0]))
				mid_y2 := i64(math.round(p0[1] + p1[1]))
				if band_edges_contains_twice(band[:], mid_x2, mid_y2) {
					q0, q1 := to_point(p0, vertical), to_point(p1, vertical)
					if len(run) == 0 || run[len(run) - 1] != q0 {
						if len(run) > 0 {flush(out, layer_index, &run, &piece_length, min_piece, line_width, allocator)}
						append(&run, q0)
					}
					if run[len(run) - 1] != q1 {append(&run, q1)}
					piece_length += math.hypot(p1[0] - p0[0], p1[1] - p0[1])
				} else if len(run) > 0 {
					flush(out, layer_index, &run, &piece_length, min_piece, line_width, allocator)
				}
			}
		}
		flush(out, layer_index, &run, &piece_length, min_piece, line_width, allocator)
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
	// Each zig-zag row has 4 sides of path per 3 sides of width, and rows are sqrt(3) sides apart,
	// so the path per area equals straight rows at `spacing` when side = 4 / (3*sqrt(3)) * spacing.
	side := max(spacing * 0.7698003589195010, 800.0)
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
