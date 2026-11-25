package polygon

import "base:runtime"
import "core:math"
import "core:mem"

import contracts "../contracts"
import geometry "../geometry"

// Pure-Odin polygon offsetting supporting Miter, Round, Square, and Bevel joins.
// Builds offset contours with edge normals and cleans self-intersections via odin_boolean.
odin_offset :: proc(
	input: Polygon_Set,
	delta: contracts.Micrometres,
	join_type: Polygon_Join_Type,
	miter_limit, arc_tolerance: f64,
	limits := DEFAULT_POLYGON_LIMITS,
	allocator := context.allocator,
) -> (Polygon_Set, Polygon_Error) {
	assert(
		allocator.procedure != context.temp_allocator.procedure || allocator.data != context.temp_allocator.data,
		"odin_offset output allocator must not be context.temp_allocator (rewound internally)",
	)
	if err := polygon_set_validate(input, limits); err != .None {return {}, err}
	if i64(delta) < -geometry.MAX_PLANAR_COORDINATE_UM ||
	   i64(delta) > geometry.MAX_PLANAR_COORDINATE_UM {
		return {}, .Coordinate_Range
	}
	if math.is_nan(miter_limit) || math.is_inf(miter_limit, 0) ||
	   math.is_nan(arc_tolerance) || math.is_inf(arc_tolerance, 0) ||
	   miter_limit < 1.0 || arc_tolerance < 0.0 {
		return {}, .Invalid_Input
	}
	if len(input.paths) == 0 {return {}, .None}
	if i64(delta) == 0 {
		return odin_vatti_boolean(input, {}, .Union, .Non_Zero, limits, allocator)
	}

	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	d := f64(i64(delta))
	abs_d := math.abs(d)
	arc_tol := arc_tolerance if arc_tolerance > 1.0 else max(2.0, abs_d * 0.01)

	// Like Clipper2 (`ClipperOffset::OffsetPoint`), every path is offset into one raw path set and a
	// single union removes the negative regions. Concave joins insert the original vertex between
	// the two offset points; the resulting negative loops are what removes over-shrunk paths
	// (a convex shape inset past its size becomes a 180-degree rotated copy, which keeps its
	// orientation, so an orientation check alone cannot detect it). When the largest path is
	// clockwise, the set is offset with the opposite sign and unioned with the Negative rule.
	largest_area: i128
	for path in input.paths {
		if path.count < 3 {continue}
		area := polygon_path_area_2(input.points[path.offset:path.offset+path.count])
		if abs(area) > abs(largest_area) {largest_area = area}
	}
	if largest_area == 0 {return {}, .None}
	reversed := largest_area < 0
	if reversed {d = -d}

	raw_pts := make([dynamic]Polygon_Point, 0, len(input.points) * 3, context.temp_allocator)
	raw_paths := make([dynamic]Polygon_Path, 0, len(input.paths), context.temp_allocator)

	for path in input.paths {
		start := int(path.offset)
		n := int(path.count)
		if n < 3 {continue}
		ring := input.points[start:start+n]
		if polygon_path_area_2(ring) == 0 {continue}

		// Unit right-hand normals: for a CCW outer ring they point outward.
		normals := make([][2]f64, n, context.temp_allocator)
		for i in 0..<n {
			a := ring[i]
			b := ring[(i + 1) % n]
			dx := f64(i64(b.x) - i64(a.x))
			dy := f64(i64(b.y) - i64(a.y))
			l := math.sqrt(dx*dx + dy*dy)
			if l < 1e-9 {
				normals[i] = {0, 0}
			} else {
				normals[i] = {dy / l, -dx / l}
			}
		}

		p_off := u64(len(raw_pts))
		added := 0
		for i in 0..<n {
			v := ring[i]
			vx, vy := f64(i64(v.x)), f64(i64(v.y))
			n0 := normals[(i + n - 1) % n]
			n1 := normals[i]
			if (n0[0] == 0 && n0[1] == 0) || (n1[0] == 0 && n1[1] == 0) {continue}

			cross := n0[0]*n1[1] - n0[1]*n1[0]
			dot := clamp(n0[0]*n1[0] + n0[1]*n1[1], -1.0, 1.0)

			p0 := Polygon_Point{
				x = contracts.Micrometres(i64(math.round(vx + d*n0[0]))),
				y = contracts.Micrometres(i64(math.round(vy + d*n0[1]))),
			}
			p1 := Polygon_Point{
				x = contracts.Micrometres(i64(math.round(vx + d*n1[0]))),
				y = contracts.Micrometres(i64(math.round(vy + d*n1[1]))),
			}

			// Concave with respect to the offset direction (not a 180-degree spike).
			if dot > -0.999 && cross * d < 0 {
				odin_offset_push(&raw_pts, &added, p0)
				odin_offset_push(&raw_pts, &added, v)
				odin_offset_push(&raw_pts, &added, p1)
				continue
			}

			switch join_type {
			case .Miter:
				denom := 1.0 + dot
				if denom > 1e-9 && 2.0 / denom <= miter_limit * miter_limit {
					scale := 1.0 / denom
					odin_offset_push(&raw_pts, &added, {
						x = contracts.Micrometres(i64(math.round(vx + d*(n0[0] + n1[0])*scale))),
						y = contracts.Micrometres(i64(math.round(vy + d*(n0[1] + n1[1])*scale))),
					})
				} else {
					prev := ring[(i + n - 1) % n]
					odin_offset_square(&raw_pts, &added, {f64(i64(prev.x)), f64(i64(prev.y))}, {vx, vy}, n0, n1, d)
				}

			case .Bevel:
				odin_offset_push(&raw_pts, &added, p0)
				odin_offset_push(&raw_pts, &added, p1)

			case .Square:
				prev := ring[(i + n - 1) % n]
				odin_offset_square(&raw_pts, &added, {f64(i64(prev.x)), f64(i64(prev.y))}, {vx, vy}, n0, n1, d)

			case .Round:
				a0 := math.atan2(d*n0[1], d*n0[0])
				a1 := math.atan2(d*n1[1], d*n1[0])
				sweep := a1 - a0
				// Negating both normals keeps the turn direction, so the sweep follows `cross`.
				if cross > 0 || (cross == 0 && d > 0) {
					for sweep < 0 {sweep += 2.0 * math.PI}
				} else {
					for sweep > 0 {sweep -= 2.0 * math.PI}
				}
				steps := 1
				if abs_d > arc_tol {
					step_ang := 2.0 * math.acos(clamp(1.0 - arc_tol/abs_d, -1.0, 1.0))
					if step_ang > 1e-3 {
						steps = max(1, min(32, int(math.ceil(math.abs(sweep) / step_ang))))
					}
				}
				for s in 0..=steps {
					ang := a0 + sweep * (f64(s) / f64(steps))
					odin_offset_push(&raw_pts, &added, {
						x = contracts.Micrometres(i64(math.round(vx + abs_d*math.cos(ang)))),
						y = contracts.Micrometres(i64(math.round(vy + abs_d*math.sin(ang)))),
					})
				}
			}
		}

		for added > 1 && raw_pts[len(raw_pts)-1] == raw_pts[int(p_off)] {
			pop(&raw_pts)
			added -= 1
		}
		if added < 3 {
			resize(&raw_pts, int(p_off))
			continue
		}
		append(&raw_paths, Polygon_Path{offset = p_off, count = u64(added)})
	}

	if len(raw_paths) == 0 {return {}, .None}
	raw_set := Polygon_Set{points = raw_pts[:], paths = raw_paths[:]}
	return odin_vatti_boolean(raw_set, {}, .Union, .Negative if reversed else .Positive, limits, allocator)
}

// Clipper2's `DoSquare`: cut the corner at vertex `v` perpendicular to the averaged edge direction,
// |d| beyond `v`, and emit the cut's intersection with the previous edge's offset line and that
// point mirrored through the cut's centre.
@(private = "file")
odin_offset_square :: proc(pts: ^[dynamic]Polygon_Point, added: ^int, prev, v, n0, n1: [2]f64, d: f64) {
	vec := [2]f64{-n0[1] + n1[1], n0[0] - n1[0]}
	vl := math.hypot(vec[0], vec[1])
	if vl < 1e-12 {
		odin_offset_push(pts, added, {x = contracts.Micrometres(i64(math.round(v[0] + d*n0[0]))), y = contracts.Micrometres(i64(math.round(v[1] + d*n0[1])))})
		odin_offset_push(pts, added, {x = contracts.Micrometres(i64(math.round(v[0] + d*n1[0]))), y = contracts.Micrometres(i64(math.round(v[1] + d*n1[1])))})
		return
	}
	vec = {vec[0] / vl, vec[1] / vl}
	abs_d := math.abs(d)
	q := [2]f64{v[0] + abs_d*vec[0], v[1] + abs_d*vec[1]}
	pt1 := [2]f64{q[0] + d*vec[1], q[1] - d*vec[0]}
	pt2 := [2]f64{q[0] - d*vec[1], q[1] + d*vec[0]}
	pt3 := [2]f64{prev[0] + d*n0[0], prev[1] + d*n0[1]}
	pt4 := [2]f64{v[0] + d*n0[0], v[1] + d*n0[1]}
	pt := q
	// Line intersection of pt1-pt2 with pt3-pt4.
	dx1, dy1 := pt2[0] - pt1[0], pt2[1] - pt1[1]
	dx2, dy2 := pt4[0] - pt3[0], pt4[1] - pt3[1]
	det := dy1*dx2 - dy2*dx1
	if det != 0 {
		t := ((pt1[0] - pt3[0])*dy2 - (pt1[1] - pt3[1])*dx2) / det
		pt = {pt1[0] + t*dx1, pt1[1] + t*dy1}
	}
	mirrored := [2]f64{q[0] + (q[0] - pt[0]), q[1] + (q[1] - pt[1])}
	odin_offset_push(pts, added, {x = contracts.Micrometres(i64(math.round(pt[0]))), y = contracts.Micrometres(i64(math.round(pt[1])))})
	odin_offset_push(pts, added, {x = contracts.Micrometres(i64(math.round(mirrored[0]))), y = contracts.Micrometres(i64(math.round(mirrored[1])))})
}

@(private = "file")
odin_offset_push :: proc(pts: ^[dynamic]Polygon_Point, added: ^int, pt: Polygon_Point) {
	if added^ > 0 && pts[len(pts)-1] == pt {return}
	append(pts, pt)
	added^ += 1
}
