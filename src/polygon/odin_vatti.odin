package polygon

import "base:runtime"
import "core:math"
import "core:mem"
import "core:slice"

import contracts "../contracts"
import geometry "../geometry"

@(private = "file")
Vatti_Seg :: struct {
	ax, ay:  i64,
	bx, by:  i64,
	min_x:   i64,
	max_x:   i64,
	min_y:   i64,
	max_y:   i64,
	is_clip: bool,
}

@(private = "file")
Vatti_Split :: struct {
	t:  f64,
	px: i64,
	py: i64,
}

@(private = "file")
Vatti_Atomic_Vert :: struct {
	x0, y0:      i64, // bottom (y0 < y1)
	x1, y1:      i64, // top
	slope:       f64, // (x1 - x0) / (y1 - y0), precomputed once
	dw_subj:     i32, // +1 for downward subject edge (entering interior L->R), -1 for upward
	dw_clip:     i32,
	s0, s1:      int, // scanbeam indices for y0, y1
	run_verdict: i8,  // active verdict in current run: 0, +1 (bot->top), -1 (top->bot)
	run_s_start: int,
}

@(private = "file")
Vatti_Atomic_Horiz :: struct {
	x0, x1: i64, // x0 < x1
	y:      i64,
}

@(private = "file")
Slab_Interval :: struct {
	x_bot:  f64, // X coordinate at bottom of slab (ys[s])
	x_top:  f64, // X coordinate at top of slab (ys[s+1])
	in_res: bool, // boolean result to the RIGHT of this edge
}

// O((N+K) log N) Vatti scanbeam active-edge-table boolean engine.
// Supports Union, Intersection, Difference, Xor across Non_Zero, Even_Odd, Positive, Negative.
odin_vatti_boolean :: proc(
	subjects, clips: Polygon_Set,
	operation: Polygon_Operation,
	fill_rule: Polygon_Fill_Rule,
	limits := DEFAULT_POLYGON_LIMITS,
	allocator := context.allocator,
) -> (Polygon_Set, Polygon_Error) {
	if operation == .Invalid {return {}, .Invalid_Input}
	if err := polygon_set_validate(subjects, limits); err != .None {return {}, err}
	if err := polygon_set_validate(clips, limits); err != .None {return {}, err}

	if len(subjects.paths) == 0 && len(clips.paths) == 0 {return {}, .None}
	if operation == .Intersection && (len(subjects.paths) == 0 || len(clips.paths) == 0) {return {}, .None}
	if operation == .Difference && len(subjects.paths) == 0 {return {}, .None}

	// Fast path: identical subjects and clips (common on vertical walls across consecutive layers).
	if len(subjects.paths) > 0 && len(subjects.paths) == len(clips.paths) &&
	   len(subjects.points) == len(clips.points) &&
	   slice.equal(subjects.paths, clips.paths) &&
	   slice.equal(subjects.points, clips.points) {
		switch operation {
		case .Difference, .Xor:
			return {}, .None
		case .Intersection, .Union:
			return vatti_canonicalize_set(subjects, limits, allocator)
		case .Invalid:
			return {}, .Invalid_Input
		}
	}

	// Fast path: disjoint bounding boxes for Intersection / Difference.
	if len(subjects.points) > 0 && len(clips.points) > 0 &&
	   (operation == .Intersection || operation == .Difference) {
		s_min_x, s_min_y, s_max_x, s_max_y := vatti_set_bounds(subjects)
		c_min_x, c_min_y, c_max_x, c_max_y := vatti_set_bounds(clips)
		if s_max_x < c_min_x || c_max_x < s_min_x || s_max_y < c_min_y || c_max_y < s_min_y {
			if operation == .Intersection {return {}, .None}
			return vatti_canonicalize_set(subjects, limits, allocator)
		}
	}

	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Step 1: Collect raw directed segments from subjects and clips.
	all_segs := make([dynamic]Vatti_Seg, 0, len(subjects.points) + len(clips.points), context.temp_allocator)
	vatti_collect_segs(subjects, false, &all_segs)
	vatti_collect_segs(clips, true, &all_segs)
	if len(all_segs) == 0 {return {}, .None}

	// Step 2: Snap rounding (Hobby). Every vertex and every rounded intersection point is a hot
	// pixel, a unit square around an integer point. Each segment is routed through the centre of
	// every hot pixel it passes through, and collinear overlaps are split at existing endpoints.
	// The resulting edges meet only at endpoints or coincide, so no two edges cross inside a
	// scanbeam slab. (Rounding split points and re-splitting does not converge in general.)
	skip_same_set := len(clips.paths) > 0 && (operation == .Intersection || operation == .Difference)
	segs, crossing_count := vatti_snap_round(all_segs[:], skip_same_set)
	first_pass_splits := crossing_count

	// Fast path for non-self-intersecting single-ring Union (covers ~80% of odin_offset calls!).
	if first_pass_splits == 0 && operation == .Union && len(clips.paths) == 0 && len(subjects.paths) == 1 {
		area := polygon_path_area_2(subjects.points)
		if area == 0 {return {}, .None}
		if fill_rule == .Positive && area < 0 {return {}, .None}
		if fill_rule == .Negative && area > 0 {return {}, .None}
		if area > 0 {
			return vatti_canonicalize_set(subjects, limits, allocator)
		}
	}

	// Build flat atomic vertical/slanted edges and horizontal edges (no hash maps).
	verts := make([dynamic]Vatti_Atomic_Vert, 0, len(segs), context.temp_allocator)
	horizs := make([dynamic]Vatti_Atomic_Horiz, 0, len(segs) / 4 + 8, context.temp_allocator)
	for seg in segs {
		ax, ay, bx, by := seg.ax, seg.ay, seg.bx, seg.by
		if ay == by {
			append(&horizs, Vatti_Atomic_Horiz{x0 = min(ax, bx), x1 = max(ax, bx), y = ay})
			continue
		}
		x0, y0, x1, y1: i64
		dw: i32
		if ay < by {
			x0, y0, x1, y1 = ax, ay, bx, by
			dw = -1
		} else {
			x0, y0, x1, y1 = bx, by, ax, ay
			dw = +1
		}
		append(&verts, Vatti_Atomic_Vert{
			x0      = x0,
			y0      = y0,
			x1      = x1,
			y1      = y1,
			slope   = f64(x1 - x0) / f64(y1 - y0),
			dw_subj = 0 if seg.is_clip else dw,
			dw_clip = dw if seg.is_clip else 0,
		})
	}

	if len(verts) == 0 {return {}, .None}

	// Sort vertical edges by (y0, x0, y1, x1) and merge coincident edges in-place (already sorted by y0!).
	fast_sort(verts[:], proc(a, b: Vatti_Atomic_Vert) -> bool {
		if a.y0 != b.y0 {return a.y0 < b.y0}
		if a.x0 != b.x0 {return a.x0 < b.x0}
		if a.y1 != b.y1 {return a.y1 < b.y1}
		return a.x1 < b.x1
	})
	vw := 0
	for vi in 0..<len(verts) {
		v := verts[vi]
		if vw > 0 &&
		   verts[vw - 1].y0 == v.y0 && verts[vw - 1].x0 == v.x0 &&
		   verts[vw - 1].y1 == v.y1 && verts[vw - 1].x1 == v.x1 {
			verts[vw - 1].dw_subj += v.dw_subj
			verts[vw - 1].dw_clip += v.dw_clip
		} else {
			verts[vw] = v
			vw += 1
		}
	}
	resize(&verts, vw)

	// Sort and deduplicate horizontal edges by (y, x0, x1) in-place.
	if len(horizs) > 1 {
		fast_sort(horizs[:], proc(a, b: Vatti_Atomic_Horiz) -> bool {
			if a.y != b.y {return a.y < b.y}
			if a.x0 != b.x0 {return a.x0 < b.x0}
			return a.x1 < b.x1
		})
		hw := 1
		for hi in 1..<len(horizs) {
			if horizs[hi] != horizs[hw - 1] {
				horizs[hw] = horizs[hi]
				hw += 1
			}
		}
		resize(&horizs, hw)
	}

	// Step 3: Build sorted unique scanbeam Y coordinates.
	raw_ys := make([dynamic]i64, 0, len(verts)*2 + len(horizs), context.temp_allocator)
	for v in verts {
		append(&raw_ys, v.y0)
		append(&raw_ys, v.y1)
	}
	for h in horizs {
		append(&raw_ys, h.y)
	}
	fast_sort(raw_ys[:], proc(a, b: i64) -> bool {return a < b})
	ys := make([dynamic]i64, 0, len(raw_ys), context.temp_allocator)
	for y in raw_ys {
		if len(ys) == 0 || ys[len(ys)-1] != y {
			append(&ys, y)
		}
	}
	num_y := len(ys)
	if num_y < 2 {return {}, .None}

	// Sweep slabs s = 0 ..< num_y maintaining a single in-place Active Edge Table (AET).
	Active_Entry :: struct {idx: int, x_mid: f64, slope: f64}
	aet := make([dynamic]Active_Entry, 0, 64, context.temp_allocator)
	prev_slab := make([dynamic]Slab_Interval, 0, 64, context.temp_allocator)
	cur_slab := make([dynamic]Slab_Interval, 0, 64, context.temp_allocator)
	kept_edges := make([dynamic]Vatti_Dir_Edge, 0, len(verts) + len(horizs), context.temp_allocator)

	need_slab_intervals := len(horizs) > 0
	next_vert := 0
	next_horiz := 0
	for s in 0..<num_y {
		y_cur := ys[s]
		// Flush expiring edges (y1 <= y_cur) in-place.
		w := 0
		for entry in aet {
			v := &verts[entry.idx]
			if v.y1 <= y_cur {
				if v.run_verdict != 0 {
					vatti_emit_vert_run(&kept_edges, v^, ys[:], v.run_s_start, s, v.run_verdict)
					v.run_verdict = 0
				}
			} else {
				aet[w] = entry
				w += 1
			}
		}
		resize(&aet, w)

		h_start := next_horiz
		for next_horiz < len(horizs) && horizs[next_horiz].y == y_cur {
			next_horiz += 1
		}
		has_horiz_here := h_start < next_horiz
		has_horiz_next := next_horiz < len(horizs) && s + 1 < num_y && horizs[next_horiz].y == ys[s + 1]
		record_slab := need_slab_intervals && (has_horiz_here || has_horiz_next)
		clear(&cur_slab)

		if s + 1 < num_y {
			for next_vert < len(verts) && verts[next_vert].y0 == y_cur {
				append(&aet, Active_Entry{idx = next_vert, slope = verts[next_vert].slope})
				next_vert += 1
			}

			if len(aet) > 0 {
				y_mid := 0.5 * f64(y_cur + ys[s + 1])
				for &entry in aet {
					v := verts[entry.idx]
					entry.x_mid = f64(v.x0) + entry.slope * (y_mid - f64(v.y0))
				}
				// Insertion sort on nearly-sorted AET (O(k) in the common non-crossing case).
				for ai := 1; ai < len(aet); ai += 1 {
					key := aet[ai]
					aj := ai - 1
					for aj >= 0 && (aet[aj].x_mid > key.x_mid ||
					    (aet[aj].x_mid == key.x_mid && aet[aj].slope > key.slope)) {
						aet[aj + 1] = aet[aj]
						aj -= 1
					}
					aet[aj + 1] = key
				}

				w_subj: i32 = 0
				w_clip: i32 = 0
				in_prev := vatti_bool_eval(
					vatti_fill_inside(w_subj, fill_rule),
					vatti_fill_inside(w_clip, fill_rule),
					operation,
				)
				for entry in aet {
					v := &verts[entry.idx]
					w_subj += v.dw_subj
					w_clip += v.dw_clip
					in_next := vatti_bool_eval(
						vatti_fill_inside(w_subj, fill_rule),
						vatti_fill_inside(w_clip, fill_rule),
						operation,
					)
					if record_slab {
						x_bot := f64(v.x0) + entry.slope * f64(y_cur - v.y0)
						x_top := f64(v.x0) + entry.slope * f64(ys[s + 1] - v.y0)
						append(&cur_slab, Slab_Interval{x_bot = x_bot, x_top = x_top, in_res = in_next})
					}

					slab_verdict: i8 = 0
					if in_prev && !in_next {
						slab_verdict = +1 // interior on left -> emit bottom->top
					} else if !in_prev && in_next {
						slab_verdict = -1 // interior on right -> emit top->bottom
					}
					if slab_verdict != v.run_verdict {
						if v.run_verdict != 0 {
							vatti_emit_vert_run(&kept_edges, v^, ys[:], v.run_s_start, s, v.run_verdict)
						}
						v.run_verdict = slab_verdict
						v.run_s_start = s
					}
					in_prev = in_next
				}
			}
		}

		// Classify horizontal edges lying on scanbeam y_cur using prev_slab vs cur_slab.
		if has_horiz_here {
			for hi in h_start..<next_horiz {
				h := horizs[hi]
				xm := 0.5 * f64(h.x0 + h.x1)
				in_below := vatti_slab_lookup_top(prev_slab[:], xm)
				in_above := vatti_slab_lookup_bot(cur_slab[:], xm)
				if in_above && !in_below {
					append(&kept_edges, Vatti_Dir_Edge{ax = h.x0, ay = h.y, bx = h.x1, by = h.y})
				} else if !in_above && in_below {
					append(&kept_edges, Vatti_Dir_Edge{ax = h.x1, ay = h.y, bx = h.x0, by = h.y})
				}
			}
		}

		if need_slab_intervals {
			prev_slab, cur_slab = cur_slab, prev_slab
		}
	}

	if len(kept_edges) == 0 {return {}, .None}

	raw_loops := vatti_trace_loops(kept_edges[:], context.temp_allocator)
	if len(raw_loops) == 0 {return {}, .None}
	return vatti_canonicalize_loops(raw_loops, limits, allocator)
}

// Snap-rounds `segs` (see step 2 of `odin_vatti_boolean`) into pieces allocated on the temp
// allocator. Returns the pieces and the number of proper intersections or overlaps found, which is
// zero exactly when the input segments neither cross nor overlap.
@(private = "file")
vatti_snap_round :: proc(segs: []Vatti_Seg, skip_same_set: bool) -> (pieces: [dynamic]Vatti_Seg, crossings: int) {
	n_segs := len(segs)
	Seg_Ord :: struct {idx: int, min_x: i64}
	seg_ords := make([]Seg_Ord, n_segs, context.temp_allocator)
	for i in 0..<n_segs {seg_ords[i] = {idx = i, min_x = segs[i].min_x}}
	fast_sort(seg_ords, proc(a, b: Seg_Ord) -> bool {return a.min_x < b.min_x})

	// Hot pixels are every endpoint and every rounded proper intersection. Endpoint pixels are
	// tested in the same pair sweep that finds intersections (a segment passing within one unit of
	// another segment's endpoint has an overlapping widened box); intersection pixels are few and
	// are looked up per segment afterwards.
	Snap_Item :: struct {seg: int, t: f64, x, y: i64}
	snaps := make([dynamic]Snap_Item, 0, 64, context.temp_allocator)
	try_snap :: proc(snaps: ^[dynamic]Snap_Item, idx: int, sg: Vatti_Seg, h: [2]i64) {
		if (h[0] == sg.ax && h[1] == sg.ay) || (h[0] == sg.bx && h[1] == sg.by) {return}
		if h[0] < sg.min_x - 1 || h[0] > sg.max_x + 1 || h[1] < sg.min_y - 1 || h[1] > sg.max_y + 1 {return}
		if !vatti_segment_hits_pixel(sg, h) {return}
		dx := f64(sg.bx - sg.ax)
		dy := f64(sg.by - sg.ay)
		t := (f64(h[0] - sg.ax)*dx + f64(h[1] - sg.ay)*dy) / (dx*dx + dy*dy)
		append(snaps, Snap_Item{idx, t, h[0], h[1]})
	}
	hot := make([dynamic][2]i64, 0, 16, context.temp_allocator)
	for oi in 0..<n_segs {
		i := seg_ords[oi].idx
		sa := segs[i]
		for oj := oi + 1; oj < n_segs; oj += 1 {
			if seg_ords[oj].min_x > sa.max_x + 1 {break}
			j := seg_ords[oj].idx
			sb := segs[j]
			if sb.max_y < sa.min_y - 1 || sb.min_y > sa.max_y + 1 {continue}
			try_snap(&snaps, i, sa, {sb.ax, sb.ay})
			try_snap(&snaps, i, sa, {sb.bx, sb.by})
			try_snap(&snaps, j, sb, {sa.ax, sa.ay})
			try_snap(&snaps, j, sb, {sa.bx, sa.by})
			if sb.min_x > sa.max_x || sb.max_y < sa.min_y || sb.min_y > sa.max_y {continue}
			if skip_same_set && sa.is_clip == sb.is_clip {continue}
			if px, py, ta, tb, hit := vatti_seg_intersect(sa, sb); hit {
				if (ta > 1e-9 && ta < 1.0 - 1e-9) || (tb > 1e-9 && tb < 1.0 - 1e-9) {
					append(&hot, [2]i64{px, py})
					crossings += 1
				}
			} else if vatti_segs_collinear(sa, sb) &&
			          max(sa.min_x, sb.min_x) <= min(sa.max_x, sb.max_x) &&
			          max(sa.min_y, sb.min_y) <= min(sa.max_y, sb.max_y) {
				crossings += 1
			}
		}
	}
	if len(hot) > 0 {
		fast_sort(hot[:], proc(a, b: [2]i64) -> bool {
			if a[0] != b[0] {return a[0] < b[0]}
			return a[1] < b[1]
		})
		unique := 0
		for h in hot {
			if unique == 0 || hot[unique - 1] != h {
				hot[unique] = h
				unique += 1
			}
		}
		resize(&hot, unique)
		for sg, i in segs {
			lo, hi := 0, len(hot)
			for lo < hi {
				mid := (lo + hi) / 2
				if hot[mid][0] < sg.min_x - 1 {lo = mid + 1} else {hi = mid}
			}
			for k := lo; k < len(hot) && hot[k][0] <= sg.max_x + 1; k += 1 {
				try_snap(&snaps, i, sg, hot[k])
			}
		}
	}
	if len(snaps) == 0 && crossings == 0 {
		pieces = make([dynamic]Vatti_Seg, 0, n_segs, context.temp_allocator)
		append(&pieces, ..segs)
		return
	}
	fast_sort(snaps[:], proc(a, b: Snap_Item) -> bool {
		if a.seg != b.seg {return a.seg < b.seg}
		return a.t < b.t
	})

	// Route each segment through its hot pixels in order along the segment. Parents are visited
	// in min-x order, so the pieces come out nearly sorted by min-x.
	snap_offsets := make([]int, n_segs + 1, context.temp_allocator)
	for sn in snaps {snap_offsets[sn.seg + 1] += 1}
	for i in 0..<n_segs {snap_offsets[i + 1] += snap_offsets[i]}
	routed := make([dynamic]Vatti_Seg, 0, n_segs + len(snaps), context.temp_allocator)
	for oi in 0..<n_segs {
		i := seg_ords[oi].idx
		sg := segs[i]
		px, py := sg.ax, sg.ay
		for sn in snaps[snap_offsets[i]:snap_offsets[i + 1]] {
			if sn.x == px && sn.y == py {continue}
			vatti_append_piece(&routed, px, py, sn.x, sn.y, sg.is_clip)
			px, py = sn.x, sn.y
		}
		vatti_append_piece(&routed, px, py, sg.bx, sg.by, sg.is_clip)
	}

	// Split collinear overlaps at the other piece's endpoints (exact points, no rounding).
	n_routed := len(routed)
	route_ords := make([]Seg_Ord, n_routed, context.temp_allocator)
	for i in 0..<n_routed {route_ords[i] = {idx = i, min_x = routed[i].min_x}}
	// Insertion sort: the pieces are nearly sorted already.
	for ai := 1; ai < n_routed; ai += 1 {
		key := route_ords[ai]
		aj := ai - 1
		for aj >= 0 && route_ords[aj].min_x > key.min_x {
			route_ords[aj + 1] = route_ords[aj]
			aj -= 1
		}
		route_ords[aj + 1] = key
	}
	Flat_Split :: struct {
		seg_idx: int,
		t:       f64,
		px, py:  i64,
	}
	splits := make([dynamic]Flat_Split, 0, 16, context.temp_allocator)
	for oi in 0..<n_routed {
		i := route_ords[oi].idx
		sa := routed[i]
		for oj := oi + 1; oj < n_routed; oj += 1 {
			if route_ords[oj].min_x > sa.max_x {break}
			j := route_ords[oj].idx
			sb := routed[j]
			if sb.max_y < sa.min_y || sb.min_y > sa.max_y {continue}
			if !vatti_segs_collinear(sa, sb) {continue}
			vatti_maybe_split_flat(&splits, i, sa, sb.ax, sb.ay)
			vatti_maybe_split_flat(&splits, i, sa, sb.bx, sb.by)
			vatti_maybe_split_flat(&splits, j, sb, sa.ax, sa.ay)
			vatti_maybe_split_flat(&splits, j, sb, sa.bx, sa.by)
		}
	}
	pieces = make([dynamic]Vatti_Seg, 0, n_routed + len(splits), context.temp_allocator)
	if len(splits) == 0 {
		append(&pieces, ..routed[:])
		return
	}
	fast_sort(splits[:], proc(a, b: Flat_Split) -> bool {
		if a.seg_idx != b.seg_idx {return a.seg_idx < b.seg_idx}
		return a.t < b.t
	})
	ks := 0
	for i in 0..<n_routed {
		sg := routed[i]
		px, py := sg.ax, sg.ay
		for ks < len(splits) && splits[ks].seg_idx == i {
			vatti_append_piece(&pieces, px, py, splits[ks].px, splits[ks].py, sg.is_clip)
			px, py = splits[ks].px, splits[ks].py
			ks += 1
		}
		vatti_append_piece(&pieces, px, py, sg.bx, sg.by, sg.is_clip)
	}
	return
}

// Whether segment `sg` passes through the closed unit square centred on hot pixel `h`.
@(private = "file")
vatti_segment_hits_pixel :: proc(sg: Vatti_Seg, h: [2]i64) -> bool {
	x0, y0 := f64(sg.ax - h[0]), f64(sg.ay - h[1])
	dx, dy := f64(sg.bx - sg.ax), f64(sg.by - sg.ay)
	t0, t1 := 0.0, 1.0
	p := [4]f64{-dx, dx, -dy, dy}
	q := [4]f64{x0 + 0.5, 0.5 - x0, y0 + 0.5, 0.5 - y0}
	for i in 0..<4 {
		if p[i] == 0 {
			if q[i] < 0 {return false}
		} else {
			t := q[i] / p[i]
			if p[i] < 0 {t0 = max(t0, t)} else {t1 = min(t1, t)}
			if t0 > t1 {return false}
		}
	}
	return true
}

@(private = "file")
vatti_append_piece :: proc(out: ^[dynamic]Vatti_Seg, ax, ay, bx, by: i64, is_clip: bool) {
	if ax == bx && ay == by {return}
	append(out, Vatti_Seg{
		ax = ax, ay = ay, bx = bx, by = by,
		min_x = min(ax, bx), max_x = max(ax, bx),
		min_y = min(ay, by), max_y = max(ay, by),
		is_clip = is_clip,
	})
}

@(private = "file")
vatti_emit_vert_run :: proc(
	out: ^[dynamic]Vatti_Dir_Edge,
	v: Vatti_Atomic_Vert,
	ys: []i64,
	s_start, s_end: int,
	verdict: i8,
) {
	if s_end <= s_start {return}
	yb := ys[s_start]
	yt := ys[s_end]
	xb := v.x0 if yb == v.y0 else v.x0 + i64(math.round(v.slope * f64(yb - v.y0)))
	xt := v.x1 if yt == v.y1 else v.x0 + i64(math.round(v.slope * f64(yt - v.y0)))
	if xb == xt && yb == yt {return}
	if verdict == +1 {
		append(out, Vatti_Dir_Edge{ax = xb, ay = yb, bx = xt, by = yt})
	} else if verdict == -1 {
		append(out, Vatti_Dir_Edge{ax = xt, ay = yt, bx = xb, by = yb})
	}
}

@(private = "file")
Vatti_Dir_Edge :: struct {
	ax, ay: i64,
	bx, by: i64,
	used:   bool,
}

@(private = "file")
vatti_collect_segs :: proc(set: Polygon_Set, is_clip: bool, out: ^[dynamic]Vatti_Seg) {
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
			append(out, Vatti_Seg{
				ax = ax, ay = ay, bx = bx, by = by,
				min_x = min(ax, bx), max_x = max(ax, bx),
				min_y = min(ay, by), max_y = max(ay, by),
				is_clip = is_clip,
			})
		}
	}
}

@(private = "file")
VATTI_I64_SAFE_DELTA :: i64(2_000_000_000)

@(private = "file")
vatti_seg_intersect :: proc(a, b: Vatti_Seg) -> (px, py: i64, ta, tb: f64, hit: bool) {
	dax := a.bx - a.ax
	day := a.by - a.ay
	dbx := b.bx - b.ax
	dby := b.by - b.ay
	rx := b.ax - a.ax
	ry := b.ay - a.ay
	if abs(dax) < VATTI_I64_SAFE_DELTA && abs(day) < VATTI_I64_SAFE_DELTA &&
	   abs(dbx) < VATTI_I64_SAFE_DELTA && abs(dby) < VATTI_I64_SAFE_DELTA &&
	   abs(rx) < VATTI_I64_SAFE_DELTA && abs(ry) < VATTI_I64_SAFE_DELTA {
		denom := dax*dby - day*dbx
		if denom == 0 {return 0, 0, 0, 0, false}
		num_a := rx*dby - ry*dbx
		num_b := rx*day - ry*dax
		if denom > 0 {
			if num_a < 0 || num_a > denom || num_b < 0 || num_b > denom {return 0, 0, 0, 0, false}
		} else {
			if num_a > 0 || num_a < denom || num_b > 0 || num_b < denom {return 0, 0, 0, 0, false}
		}
		ta = f64(num_a) / f64(denom)
		tb = f64(num_b) / f64(denom)
		px = a.ax + i64(math.round(ta * f64(dax)))
		py = a.ay + i64(math.round(ta * f64(day)))
		return px, py, ta, tb, true
	}
	dax128, day128 := i128(dax), i128(day)
	dbx128, dby128 := i128(dbx), i128(dby)
	denom128 := dax128*dby128 - day128*dbx128
	if denom128 == 0 {return 0, 0, 0, 0, false}
	rx128, ry128 := i128(rx), i128(ry)
	num_a128 := rx128*dby128 - ry128*dbx128
	num_b128 := rx128*day128 - ry128*dax128
	if denom128 > 0 {
		if num_a128 < 0 || num_a128 > denom128 || num_b128 < 0 || num_b128 > denom128 {return 0, 0, 0, 0, false}
	} else {
		if num_a128 > 0 || num_a128 < denom128 || num_b128 > 0 || num_b128 < denom128 {return 0, 0, 0, 0, false}
	}
	ta = f64(num_a128) / f64(denom128)
	tb = f64(num_b128) / f64(denom128)
	px = a.ax + i64(math.round(ta * f64(dax)))
	py = a.ay + i64(math.round(ta * f64(day)))
	return px, py, ta, tb, true
}

@(private = "file")
vatti_segs_collinear :: proc(a, b: Vatti_Seg) -> bool {
	dax := a.bx - a.ax
	day := a.by - a.ay
	rx0 := b.ax - a.ax
	ry0 := b.ay - a.ay
	rx1 := b.bx - a.ax
	ry1 := b.by - a.ay
	if abs(dax) < VATTI_I64_SAFE_DELTA && abs(day) < VATTI_I64_SAFE_DELTA &&
	   abs(rx0) < VATTI_I64_SAFE_DELTA && abs(ry0) < VATTI_I64_SAFE_DELTA &&
	   abs(rx1) < VATTI_I64_SAFE_DELTA && abs(ry1) < VATTI_I64_SAFE_DELTA {
		return dax*ry0 - day*rx0 == 0 && dax*ry1 - day*rx1 == 0
	}
	return i128(dax)*i128(ry0) - i128(day)*i128(rx0) == 0 &&
	       i128(dax)*i128(ry1) - i128(day)*i128(rx1) == 0
}

@(private = "file")
vatti_maybe_split :: proc(list: ^[dynamic]Vatti_Split, s: Vatti_Seg, px, py: i64) {
	if (px == s.ax && py == s.ay) || (px == s.bx && py == s.by) {return}
	if px < s.min_x || px > s.max_x || py < s.min_y || py > s.max_y {return}
	dx := f64(s.bx - s.ax)
	dy := f64(s.by - s.ay)
	l2 := dx*dx + dy*dy
	if l2 < 1e-9 {return}
	t := (f64(px - s.ax)*dx + f64(py - s.ay)*dy) / l2
	if t > 1e-9 && t < 1.0 - 1e-9 {
		append(list, Vatti_Split{t = t, px = px, py = py})
	}
}

@(private = "file")
vatti_find_y :: proc(ys: []i64, target: i64) -> int {
	lo := 0
	hi := len(ys) - 1
	for lo <= hi {
		mid := (lo + hi) >> 1
		if ys[mid] == target {return mid}
		if ys[mid] < target {lo = mid + 1} else {hi = mid - 1}
	}
	return lo
}

@(private = "file")
vatti_slab_lookup_bot :: proc(slab: []Slab_Interval, x: f64) -> bool {
	if len(slab) == 0 {return false}
	lo := 0
	hi := len(slab)
	for lo < hi {
		mid := (lo + hi) >> 1
		if slab[mid].x_bot <= x {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {return false}
	return slab[lo - 1].in_res
}

@(private = "file")
vatti_slab_lookup_top :: proc(slab: []Slab_Interval, x: f64) -> bool {
	if len(slab) == 0 {return false}
	lo := 0
	hi := len(slab)
	for lo < hi {
		mid := (lo + hi) >> 1
		if slab[mid].x_top <= x {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {return false}
	return slab[lo - 1].in_res
}

@(private = "file")
vatti_fill_inside :: proc(w: i32, rule: Polygon_Fill_Rule) -> bool {
	switch rule {
	case .Even_Odd: return (w & 1) != 0
	case .Non_Zero: return w != 0
	case .Positive: return w > 0
	case .Negative: return w < 0
	}
	return w != 0
}

@(private = "file")
vatti_bool_eval :: proc(in_s, in_c: bool, op: Polygon_Operation) -> bool {
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
vatti_trace_loops :: proc(edges: []Vatti_Dir_Edge, allocator: mem.Allocator) -> [][dynamic]Polygon_Point {
	n := len(edges)
	if n == 0 {return nil}

	Out_Entry :: struct {
		x, y: i64,
		idx:  int,
	}
	entries := make([]Out_Entry, n, context.temp_allocator)
	for e, idx in edges {
		entries[idx] = {x = e.ax, y = e.ay, idx = idx}
	}
	fast_sort(entries, proc(a, b: Out_Entry) -> bool {
		if a.x != b.x {return a.x < b.x}
		return a.y < b.y
	})

	find_range :: proc(entries: []Out_Entry, x, y: i64) -> (lo, hi: int) {
		l, r := 0, len(entries)
		for l < r {
			m := (l + r) >> 1
			if entries[m].x < x || (entries[m].x == x && entries[m].y < y) {
				l = m + 1
			} else {
				r = m
			}
		}
		lo = l
		hi = l
		for hi < len(entries) && entries[hi].x == x && entries[hi].y == y {
			hi += 1
		}
		return lo, hi
	}

	loops := make([dynamic][dynamic]Polygon_Point, 0, 16, allocator)
	for start_idx in 0..<n {
		if edges[start_idx].used {continue}
		loop := make([dynamic]Polygon_Point, 0, 32, allocator)
		cur_idx := start_idx
		start_x, start_y := edges[start_idx].ax, edges[start_idx].ay
		closed := false
		for step := 0; step <= n; step += 1 {
			e := &edges[cur_idx]
			if e.used {break}
			e.used = true
			append(&loop, Polygon_Point{x = contracts.Micrometres(e.ax), y = contracts.Micrometres(e.ay)})
			nx, ny := e.bx, e.by
			if nx == start_x && ny == start_y {
				closed = true
				break
			}
			lo, hi := find_range(entries, nx, ny)
			if lo == hi {break}

			// Fast path (99.9% of vertices): single outgoing edge — skip atan2 completely.
			if hi - lo == 1 {
				ci := entries[lo].idx
				if edges[ci].used {break}
				cur_idx = ci
				continue
			}

			// Multi-way junction: pick tightest left turn.
			in_ang := math.atan2(f64(e.by - e.ay), f64(e.bx - e.ax))
			best_idx := -1
			best_turn := f64(1e9)
			for k in lo..<hi {
				ci := entries[k].idx
				if edges[ci].used {continue}
				out_ang := math.atan2(f64(edges[ci].by - edges[ci].ay), f64(edges[ci].bx - edges[ci].ax))
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
vatti_canonicalize_loops :: proc(
	raw_loops: [][dynamic]Polygon_Point,
	limits: Polygon_Limits,
	allocator: mem.Allocator,
) -> (Polygon_Set, Polygon_Error) {
	canonical := make([dynamic]Polygon_Canonical_Path, 0, len(raw_loops), context.temp_allocator)
	total_points: u64
	for raw in raw_loops {
		if len(raw) < 3 {continue}
		// Iteratively remove consecutive duplicates and collinear/180-deg-spike vertices until fixed point.
		cur := make([dynamic]Polygon_Point, 0, len(raw), context.temp_allocator)
		for pt in raw {append(&cur, pt)}
		next_buf := make([dynamic]Polygon_Point, 0, len(raw), context.temp_allocator)
		for {
			clear(&next_buf)
			for pt in cur {
				if len(next_buf) == 0 || next_buf[len(next_buf)-1] != pt {
					append(&next_buf, pt)
				}
			}
			for len(next_buf) > 1 && next_buf[len(next_buf)-1] == next_buf[0] {
				pop(&next_buf)
			}
			clear(&cur)
			n := len(next_buf)
			if n < 3 {break}
			dropped := false
			for i in 0..<n {
				p_prev := next_buf[(i + n - 1) % n]
				p_cur := next_buf[i]
				p_next := next_buf[(i + 1) % n]
				c := i128(i64(p_cur.x) - i64(p_prev.x))*i128(i64(p_next.y) - i64(p_cur.y)) -
				     i128(i64(p_cur.y) - i64(p_prev.y))*i128(i64(p_next.x) - i64(p_cur.x))
				if c != 0 {
					append(&cur, p_cur)
				} else {
					dropped = true
				}
			}
			if !dropped || len(cur) < 3 {break}
		}
		if len(cur) < 3 {continue}
		area := polygon_path_area_2(cur[:])
		if area == 0 {continue}

		for pt in cur {
			if geometry.point_2_validate({x = pt.x, y = pt.y}) != .None {
				return {}, .Coordinate_Range
			}
		}
		rot := polygon_minimum_rotation(cur[:])
		if rot > 0 {slice.rotate_left(cur[:], rot)}

		pts_copy := make([]Polygon_Point, len(cur), context.temp_allocator)
		copy(pts_copy, cur[:])
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
	fast_sort(canonical[:], polygon_canonical_path_less)
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

@(private = "file")
vatti_set_bounds :: proc(set: Polygon_Set) -> (min_x, min_y, max_x, max_y: i64) {
	p0 := set.points[0]
	min_x, max_x = i64(p0.x), i64(p0.x)
	min_y, max_y = i64(p0.y), i64(p0.y)
	for p in set.points[1:] {
		x, y := i64(p.x), i64(p.y)
		if x < min_x {min_x = x}
		if x > max_x {max_x = x}
		if y < min_y {min_y = y}
		if y > max_y {max_y = y}
	}
	return
}

@(private = "file")
vatti_canonicalize_set :: proc(
	set: Polygon_Set,
	limits: Polygon_Limits,
	allocator: mem.Allocator,
) -> (Polygon_Set, Polygon_Error) {
	if len(set.paths) == 0 {return {}, .None}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	loops := make([dynamic][dynamic]Polygon_Point, 0, len(set.paths), context.temp_allocator)
	for p in set.paths {
		s := int(p.offset)
		n := int(p.count)
		if n < 3 {continue}
		ring := make([dynamic]Polygon_Point, n, context.temp_allocator)
		copy(ring[:], set.points[s:s + n])
		append(&loops, ring)
	}
	if len(loops) == 0 {return {}, .None}
	return vatti_canonicalize_loops(loops[:], limits, allocator)
}

@(private = "file")
Flat_Split_Ref :: struct {
	seg_idx: int,
	t:       f64,
	px, py:  i64,
}

@(private = "file")
vatti_maybe_split_flat :: proc(dst: ^[dynamic]$T, seg_idx: int, s: Vatti_Seg, px, py: i64) -> bool {
	dx := f64(s.bx - s.ax)
	dy := f64(s.by - s.ay)
	t: f64
	if math.abs(dx) >= math.abs(dy) {
		if math.abs(dx) < 1e-9 {return false}
		t = f64(px - s.ax) / dx
	} else {
		if math.abs(dy) < 1e-9 {return false}
		t = f64(py - s.ay) / dy
	}
	if t > 1e-9 && t < 1.0 - 1e-9 {
		append(dst, T{seg_idx = seg_idx, t = t, px = px, py = py})
		return true
	}
	return false
}
