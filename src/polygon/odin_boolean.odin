package polygon

import "core:math"
import "core:mem"
import "core:slice"

import contracts "../contracts"
import geometry "../geometry"

@(private = "file")
Raw_Seg :: struct {
	ax, ay: i64,
	bx, by: i64,
	min_x:  i64,
	max_x:  i64,
	min_y:  i64,
	max_y:  i64,
}

@(private = "file")
Split_Param :: struct {
	t:  f64,
	px: i64,
	py: i64,
}

@(private = "file")
Dir_Edge :: struct {
	ax, ay: i64,
	bx, by: i64,
	used:   bool,
}

odin_boolean :: proc(
	subjects, clips: Polygon_Set,
	operation: Polygon_Operation,
	fill_rule: Polygon_Fill_Rule,
	limits := DEFAULT_POLYGON_LIMITS,
	allocator := context.allocator,
) -> (Polygon_Set, Polygon_Error) {
	if operation == .Invalid {return {}, .Invalid_Input}
	if err := polygon_set_validate(subjects, limits); err != .None {return {}, err}
	if err := polygon_set_validate(clips, limits); err != .None {return {}, err}

	// Fast empty-input short circuits.
	if len(subjects.paths) == 0 && len(clips.paths) == 0 {
		return {}, .None
	}
	if operation == .Intersection && (len(subjects.paths) == 0 || len(clips.paths) == 0) {
		return {}, .None
	}
	if operation == .Difference && len(subjects.paths) == 0 {
		return {}, .None
	}

	// Collect raw segments from subjects and clips.
	subj_segs := make([dynamic]Raw_Seg, 0, len(subjects.points), context.temp_allocator)
	clip_segs := make([dynamic]Raw_Seg, 0, len(clips.points), context.temp_allocator)
	all_segs := make([dynamic]Raw_Seg, 0, len(subjects.points) + len(clips.points), context.temp_allocator)

	odin_collect_segments(subjects, &subj_segs, &all_segs)
	odin_collect_segments(clips, &clip_segs, &all_segs)
	if len(all_segs) == 0 {return {}, .None}

	// Sort segment indices by min_x for sweep-line intersection detection.
	n_segs := len(all_segs)
	order := make([]int, n_segs, context.temp_allocator)
	for i in 0..<n_segs {order[i] = i}
	slice.sort_by(order, proc(a, b: int) -> bool {return a < b})
	// Actually sort by all_segs[idx].min_x using insertion/quicksort via wrapper.
	Seg_Order :: struct {idx: int, min_x: i64}
	seg_orders := make([]Seg_Order, n_segs, context.temp_allocator)
	for i in 0..<n_segs {seg_orders[i] = {idx = i, min_x = all_segs[i].min_x}}
	slice.sort_by(seg_orders, proc(a, b: Seg_Order) -> bool {return a.min_x < b.min_x})

	// Per-segment split lists.
	splits := make([][dynamic]Split_Param, n_segs, context.temp_allocator)

	// Sweep-line pairwise intersection finding (only checks overlapping X and Y boxes).
	for oi in 0..<n_segs {
		i := seg_orders[oi].idx
		sa := all_segs[i]
		for oj := oi + 1; oj < n_segs; oj += 1 {
			if seg_orders[oj].min_x > sa.max_x {break}
			j := seg_orders[oj].idx
			sb := all_segs[j]
			if sb.max_y < sa.min_y || sb.min_y > sa.max_y {continue}

			// Check exact intersection / endpoint-on-segment.
			if px, py, ta, tb, hit := odin_segment_intersect(sa, sb); hit {
				if ta > 1e-9 && ta < 1.0 - 1e-9 {
					append(&splits[i], Split_Param{t = ta, px = px, py = py})
				}
				if tb > 1e-9 && tb < 1.0 - 1e-9 {
					append(&splits[j], Split_Param{t = tb, px = px, py = py})
				}
			} else if odin_segments_collinear_overlap(sa, sb) {
				// Split collinear overlapping segments at each other's endpoints.
				odin_maybe_split_endpoint(&splits[i], sa, sb.ax, sb.ay)
				odin_maybe_split_endpoint(&splits[i], sa, sb.bx, sb.by)
				odin_maybe_split_endpoint(&splits[j], sb, sa.ax, sa.ay)
				odin_maybe_split_endpoint(&splits[j], sb, sa.bx, sa.by)
			}
		}
	}

	// Build deduplicated atomic undirected edges.
	Edge_Key :: struct {ax, ay, bx, by: i64}
	seen_edges := make(map[Edge_Key]bool, n_segs * 2, context.temp_allocator)
	kept_edges := make([dynamic]Dir_Edge, 0, n_segs, context.temp_allocator)

	for i in 0..<n_segs {
		s := all_segs[i]
		pts := make([dynamic]Split_Param, 0, len(splits[i]) + 2, context.temp_allocator)
		append(&pts, Split_Param{t = 0.0, px = s.ax, py = s.ay})
		for sp in splits[i] {append(&pts, sp)}
		append(&pts, Split_Param{t = 1.0, px = s.bx, py = s.by})
		slice.sort_by(pts[:], proc(a, b: Split_Param) -> bool {return a.t < b.t})

		for k in 0..<len(pts)-1 {
			ax, ay := pts[k].px, pts[k].py
			bx, by := pts[k + 1].px, pts[k + 1].py
			if ax == bx && ay == by {continue}

			// Canonical undirected key so coincident edges are classified exactly once.
			key: Edge_Key
			if ax < bx || (ax == bx && ay < by) {
				key = {ax, ay, bx, by}
			} else {
				key = {bx, by, ax, ay}
			}
			if key in seen_edges {continue}
			seen_edges[key] = true

			// Classify left and right sides of atomic edge (key.ax, key.ay) -> (key.bx, key.by).
			in_l, in_r := odin_classify_edge_sides(
				key.ax, key.ay, key.bx, key.by,
				subj_segs[:], clip_segs[:],
				operation, fill_rule,
			)
			if in_l == in_r {continue}
			if in_l && !in_r {
				append(&kept_edges, Dir_Edge{ax = key.ax, ay = key.ay, bx = key.bx, by = key.by})
			} else {
				append(&kept_edges, Dir_Edge{ax = key.bx, ay = key.by, bx = key.ax, by = key.ay})
			}
		}
	}

	if len(kept_edges) == 0 {
		return {}, .None
	}

	// Trace closed loops from kept directed edges.
	raw_loops := odin_trace_loops(kept_edges[:], context.temp_allocator)
	if len(raw_loops) == 0 {
		return {}, .None
	}

	// Canonicalize loops (dedupe, remove collinear, drop zero-area, booth min rotation, sort).
	return odin_canonicalize_loops(raw_loops, limits, allocator)
}

@(private = "file")
odin_collect_segments :: proc(set: Polygon_Set, own_out, all_out: ^[dynamic]Raw_Seg) {
	for path in set.paths {
		start := int(path.offset)
		cnt := int(path.count)
		if cnt < 3 {continue}
		for i in 0..<cnt {
			a := set.points[start + i]
			b := set.points[start + (i + 1) % cnt]
			if a == b {continue}
			ax, ay := i64(a.x), i64(a.y)
			bx, by := i64(b.x), i64(b.y)
			seg := Raw_Seg{
				ax = ax, ay = ay, bx = bx, by = by,
				min_x = min(ax, bx), max_x = max(ax, bx),
				min_y = min(ay, by), max_y = max(ay, by),
			}
			append(own_out, seg)
			append(all_out, seg)
		}
	}
}

@(private = "file")
odin_segment_intersect :: proc(a, b: Raw_Seg) -> (px, py: i64, ta, tb: f64, hit: bool) {
	dax := i128(a.bx - a.ax)
	day := i128(a.by - a.ay)
	dbx := i128(b.bx - b.ax)
	dby := i128(b.by - b.ay)
	denom := dax*dby - day*dbx
	if denom == 0 {return 0, 0, 0, 0, false}

	rx := i128(b.ax - a.ax)
	ry := i128(b.ay - a.ay)
	num_a := rx*dby - ry*dbx
	num_b := rx*day - ry*dax

	if denom > 0 {
		if num_a < 0 || num_a > denom || num_b < 0 || num_b > denom {return 0, 0, 0, 0, false}
	} else {
		if num_a > 0 || num_a < denom || num_b > 0 || num_b < denom {return 0, 0, 0, 0, false}
	}
	ta = f64(num_a) / f64(denom)
	tb = f64(num_b) / f64(denom)
	px = a.ax + i64(math.round(ta * f64(a.bx - a.ax)))
	py = a.ay + i64(math.round(ta * f64(a.by - a.ay)))
	return px, py, ta, tb, true
}

@(private = "file")
odin_segments_collinear_overlap :: proc(a, b: Raw_Seg) -> bool {
	dax := i128(a.bx - a.ax)
	day := i128(a.by - a.ay)
	c1 := dax*i128(b.ax - a.ax) - day*i128(b.ay - a.ay)
	c2 := dax*i128(b.bx - a.ax) - day*i128(b.by - a.ay)
	return c1 == 0 && c2 == 0
}

@(private = "file")
odin_maybe_split_endpoint :: proc(list: ^[dynamic]Split_Param, s: Raw_Seg, px, py: i64) {
	if (px == s.ax && py == s.ay) || (px == s.bx && py == s.by) {return}
	if px < s.min_x || px > s.max_x || py < s.min_y || py > s.max_y {return}
	dx := f64(s.bx - s.ax)
	dy := f64(s.by - s.ay)
	len2 := dx*dx + dy*dy
	if len2 < 1e-9 {return}
	t := (f64(px - s.ax)*dx + f64(py - s.ay)*dy) / len2
	if t > 1e-9 && t < 1.0 - 1e-9 {
		append(list, Split_Param{t = t, px = px, py = py})
	}
}

@(private = "file")
odin_winding_number :: proc(px, py: f64, segs: []Raw_Seg) -> int {
	w := 0
	for s in segs {
		if py < f64(s.min_y) || py > f64(s.max_y) {continue}
		ay := f64(s.ay)
		by := f64(s.by)
		if ay <= py {
			if by > py {
				// Upward crossing: check if point is strictly left of edge.
				cross := (f64(s.bx - s.ax))*(py - ay) - (px - f64(s.ax))*(by - ay)
				if cross > 0 {w += 1}
			}
		} else {
			if by <= py {
				// Downward crossing: check if point is strictly right of edge.
				cross := (f64(s.bx - s.ax))*(py - ay) - (px - f64(s.ax))*(by - ay)
				if cross < 0 {w -= 1}
			}
		}
	}
	return w
}

@(private = "file")
odin_fill_rule_inside :: proc(w: int, rule: Polygon_Fill_Rule) -> bool {
	switch rule {
	case .Even_Odd: return (w & 1) != 0
	case .Non_Zero: return w != 0
	case .Positive: return w > 0
	case .Negative: return w < 0
	}
	return w != 0
}

@(private = "file")
odin_bool_eval :: proc(in_s, in_c: bool, op: Polygon_Operation) -> bool {
	switch op {
	case .Union:        return in_s || in_c
	case .Intersection: return in_s && in_c
	case .Difference:   return in_s && !in_c
	case .Xor:          return in_s != in_c
	case .Invalid:      return false
	}
	return false
}

@(private = "file")
odin_classify_edge_sides :: proc(
	ax, ay, bx, by: i64,
	subj_segs, clip_segs: []Raw_Seg,
	op: Polygon_Operation,
	rule: Polygon_Fill_Rule,
) -> (in_left, in_right: bool) {
	mx := 0.5 * f64(ax + bx)
	my := 0.5 * f64(ay + by)
	dx := f64(bx - ax)
	dy := f64(by - ay)
	l := math.hypot(dx, dy)
	if l < 1e-9 {return false, false}
	// Sample 0.25 um (sub-integer epsilon) to the left (-dy, dx) and right (dy, -dx) of midpoint.
	eps := 0.25 / l
	lx, ly := mx - dy*eps, my + dx*eps
	rx, ry := mx + dy*eps, my - dx*eps

	ws_l := odin_winding_number(lx, ly, subj_segs)
	ws_r := odin_winding_number(rx, ry, subj_segs)
	wc_l := odin_winding_number(lx, ly, clip_segs) if len(clip_segs) > 0 else 0
	wc_r := odin_winding_number(rx, ry, clip_segs) if len(clip_segs) > 0 else 0

	in_left = odin_bool_eval(odin_fill_rule_inside(ws_l, rule), odin_fill_rule_inside(wc_l, rule), op)
	in_right = odin_bool_eval(odin_fill_rule_inside(ws_r, rule), odin_fill_rule_inside(wc_r, rule), op)
	return
}

@(private = "file")
odin_trace_loops :: proc(edges: []Dir_Edge, allocator: mem.Allocator) -> [][dynamic]Polygon_Point {
	Vert_Key :: struct {x, y: i64}
	outgoing := make(map[Vert_Key][dynamic]int, len(edges), context.temp_allocator)
	for e, idx in edges {
		k := Vert_Key{e.ax, e.ay}
		if k not_in outgoing {
			outgoing[k] = make([dynamic]int, 0, 2, context.temp_allocator)
		}
		append(&outgoing[k], idx)
	}

	loops := make([dynamic][dynamic]Polygon_Point, 0, 16, allocator)
	for start_idx in 0..<len(edges) {
		if edges[start_idx].used {continue}
		loop := make([dynamic]Polygon_Point, 0, 16, allocator)
		cur_idx := start_idx
		start_pt := Vert_Key{edges[start_idx].ax, edges[start_idx].ay}
		closed := false
		for step := 0; step <= len(edges); step += 1 {
			e := &edges[cur_idx]
			if e.used {break}
			e.used = true
			append(&loop, Polygon_Point{x = contracts.Micrometres(e.ax), y = contracts.Micrometres(e.ay)})
			next_pt := Vert_Key{e.bx, e.by}
			if next_pt == start_pt {
				closed = true
				break
			}
			cands, has_cands := outgoing[next_pt]
			if !has_cands {break}

			// Pick unused outgoing edge with sharpest right-hand turn (keeps interior on left without crossing).
			in_ang := math.atan2(f64(e.by - e.ay), f64(e.bx - e.ax))
			best_idx := -1
			best_turn := f64(1e9)
			for ci in cands {
				if edges[ci].used {continue}
				out_ang := math.atan2(f64(edges[ci].by - edges[ci].ay), f64(edges[ci].bx - edges[ci].ax))
				// Turn angle in (0, 2*pi] measured clockwise from reverse incoming vector.
				diff := out_ang - (in_ang + math.PI)
				for diff <= 0 {diff += 2.0 * math.PI}
				for diff > 2.0 * math.PI {diff -= 2.0 * math.PI}
				if diff < best_turn {
					best_turn = diff
					best_idx = ci
				}
			}
			if best_idx < 0 {break}
			cur_idx = best_idx
		}
		if closed && len(loop) >= 3 {
			append(&loops, loop)
		}
	}
	return loops[:]
}

@(private = "file")
odin_canonicalize_loops :: proc(
	raw_loops: [][dynamic]Polygon_Point,
	limits: Polygon_Limits,
	allocator: mem.Allocator,
) -> (Polygon_Set, Polygon_Error) {
	canonical := make([dynamic]Polygon_Canonical_Path, 0, len(raw_loops), context.temp_allocator)
	total_points: u64
	for raw in raw_loops {
		if len(raw) < 3 {continue}
		// Deduplicate consecutive points and remove collinear intermediate vertices.
		cleaned := make([dynamic]Polygon_Point, 0, len(raw), context.temp_allocator)
		for pt in raw {
			if len(cleaned) == 0 || cleaned[len(cleaned)-1] != pt {
				append(&cleaned, pt)
			}
		}
		for len(cleaned) > 1 && cleaned[len(cleaned)-1] == cleaned[0] {
			pop(&cleaned)
		}
		// Remove collinear vertices in one pass.
		simplified := make([dynamic]Polygon_Point, 0, len(cleaned), context.temp_allocator)
		n := len(cleaned)
		if n >= 3 {
			for i in 0..<n {
				p_prev := cleaned[(i + n - 1) % n]
				p_cur := cleaned[i]
				p_next := cleaned[(i + 1) % n]
				c := i128(i64(p_cur.x) - i64(p_prev.x))*i128(i64(p_next.y) - i64(p_cur.y)) -
				     i128(i64(p_cur.y) - i64(p_prev.y))*i128(i64(p_next.x) - i64(p_cur.x))
				if c != 0 {
					append(&simplified, p_cur)
				}
			}
		}
		if len(simplified) < 3 {continue}
		area := polygon_path_area_2(simplified[:])
		if area == 0 {continue}

		// Validate coordinate bounds.
		coords_ok := true
		for pt in simplified {
			if geometry.point_2_validate({x = pt.x, y = pt.y}) != .None {
				coords_ok = false
				break
			}
		}
		if !coords_ok {return {}, .Coordinate_Range}

		rot := polygon_minimum_rotation(simplified[:])
		if rot > 0 {slice.rotate_left(simplified[:], rot)}

		pts_copy := make([]Polygon_Point, len(simplified), context.temp_allocator)
		copy(pts_copy, simplified[:])
		append(&canonical, Polygon_Canonical_Path{points = pts_copy, signed_area_2 = area})
		total_points += u64(len(pts_copy))
	}

	if len(canonical) == 0 {return {}, .None}
	total_area: i128
	for c in canonical {total_area += c.signed_area_2}
	if total_area <= 0 {return {}, .None}
	if u64(len(canonical)) > limits.max_output_paths || total_points > limits.max_output_points {
		return {}, .Output_Limit
	}

	slice.sort_by(canonical[:], polygon_canonical_path_less)

	result := Polygon_Set{
		points = make([]Polygon_Point, int(total_points), allocator),
		paths  = make([]Polygon_Path, len(canonical), allocator),
	}
	if result.points == nil || result.paths == nil {
		polygon_set_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	pw: u64
	for c, ci in canonical {
		result.paths[ci] = {offset = pw, count = u64(len(c.points))}
		copy(result.points[pw:pw+u64(len(c.points))], c.points)
		pw += u64(len(c.points))
	}
	return result, .None
}
