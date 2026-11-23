package polygon

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
		return odin_boolean(input, {}, .Union, .Non_Zero, limits, allocator)
	}

	d := f64(i64(delta))
	abs_d := math.abs(d)
	arc_tol := arc_tolerance if arc_tolerance > 1.0 else max(2.0, abs_d * 0.01)

	raw_pts := make([dynamic]Polygon_Point, 0, len(input.points) * 2, context.temp_allocator)
	raw_paths := make([dynamic]Polygon_Path, 0, len(input.paths), context.temp_allocator)

	for path in input.paths {
		start := int(path.offset)
		n := int(path.count)
		if n < 3 {continue}
		ring := input.points[start:start+n]

		// Precompute unit right-hand normals for each edge: for CCW outer ring, right-hand normal points outward.
		normals := make([][2]f64, n, context.temp_allocator)
		for i in 0..<n {
			a := ring[i]
			b := ring[(i + 1) % n]
			dx := f64(i64(b.x) - i64(a.x))
			dy := f64(i64(b.y) - i64(a.y))
			l := math.hypot(dx, dy)
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
			// Convex wrt offset direction when cross * d < 0 (turning outward for d > 0).
			is_convex := (cross * d) < -1e-9

			p0 := Polygon_Point{
				x = contracts.Micrometres(i64(math.round(vx + d*n0[0]))),
				y = contracts.Micrometres(i64(math.round(vy + d*n0[1]))),
			}
			p1 := Polygon_Point{
				x = contracts.Micrometres(i64(math.round(vx + d*n1[0]))),
				y = contracts.Micrometres(i64(math.round(vy + d*n1[1]))),
			}

			if !is_convex {
				// Concave corner: connect p0 -> v -> p1 so self-union trims cleanly.
				odin_offset_push(&raw_pts, &added, p0)
				odin_offset_push(&raw_pts, &added, v)
				odin_offset_push(&raw_pts, &added, p1)
				continue
			}

			switch join_type {
			case .Miter:
				denom := 1.0 + dot
				if denom > 1e-9 {
					scale := 1.0 / denom
					// Miter length ratio = sqrt(2 / (1 + dot))
					if 2.0 * scale <= miter_limit * miter_limit {
						mx := vx + d*(n0[0] + n1[0])*scale
						my := vy + d*(n0[1] + n1[1])*scale
						odin_offset_push(&raw_pts, &added, {
							x = contracts.Micrometres(i64(math.round(mx))),
							y = contracts.Micrometres(i64(math.round(my))),
						})
					} else {
						odin_offset_push(&raw_pts, &added, p0)
						odin_offset_push(&raw_pts, &added, p1)
					}
				} else {
					odin_offset_push(&raw_pts, &added, p0)
					odin_offset_push(&raw_pts, &added, p1)
				}

			case .Bevel:
				odin_offset_push(&raw_pts, &added, p0)
				odin_offset_push(&raw_pts, &added, p1)

			case .Square:
				// Extend p0 along edge0 forward by |d| and p1 along edge1 backward by |d|.
				t0x, t0y := -n0[1], n0[0]
				t1x, t1y := -n1[1], n1[0]
				q0 := Polygon_Point{
					x = contracts.Micrometres(i64(math.round(vx + d*n0[0] + abs_d*t0x))),
					y = contracts.Micrometres(i64(math.round(vy + d*n0[1] + abs_d*t0y))),
				}
				q1 := Polygon_Point{
					x = contracts.Micrometres(i64(math.round(vx + d*n1[0] - abs_d*t1x))),
					y = contracts.Micrometres(i64(math.round(vy + d*n1[1] - abs_d*t1y))),
				}
				odin_offset_push(&raw_pts, &added, p0)
				odin_offset_push(&raw_pts, &added, q0)
				odin_offset_push(&raw_pts, &added, q1)
				odin_offset_push(&raw_pts, &added, p1)

			case .Round:
				a0 := math.atan2(d*n0[1], d*n0[0])
				a1 := math.atan2(d*n1[1], d*n1[0])
				sweep := a1 - a0
				if d > 0 {
					for sweep > 0 {sweep -= 2.0 * math.PI}
				} else {
					for sweep < 0 {sweep += 2.0 * math.PI}
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
	// Positive fill rule keeps valid surviving interior regions and discards inverted negative-offset loops.
	return odin_boolean(raw_set, {}, .Union, .Positive, limits, allocator)
}

@(private = "file")
odin_offset_push :: proc(pts: ^[dynamic]Polygon_Point, added: ^int, pt: Polygon_Point) {
	if added^ > 0 && pts[len(pts)-1] == pt {return}
	append(pts, pt)
	added^ += 1
}
