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

	n_segs := len(all_segs)
	Seg_Ord :: struct {idx: int, min_x: i64}
	seg_ords := make([]Seg_Ord, n_segs, context.temp_allocator)
	for i in 0..<n_segs {seg_ords[i] = {idx = i, min_x = all_segs[i].min_x}}
	slice.sort_by(seg_ords, proc(a, b: Seg_Ord) -> bool {return a.min_x < b.min_x})

	// Step 2: Sweep-line intersection & collinear overlap splitting into a single flat buffer.
	Flat_Split :: struct {
		seg_idx: int,
		t:       f64,
		px, py:  i64,
	}
	flat_splits := make([dynamic]Flat_Split, 0, 64, context.temp_allocator)
	has_split := make([]bool, n_segs, context.temp_allocator)
	skip_same_set := len(clips.paths) > 0 && (operation == .Intersection || operation == .Difference)
	for oi in 0..<n_segs {
		i := seg_ords[oi].idx
		sa := all_segs[i]
		for oj := oi + 1; oj < n_segs; oj += 1 {
			if seg_ords[oj].min_x > sa.max_x {break}
			j := seg_ords[oj].idx
			sb := all_segs[j]
			if skip_same_set && sa.is_clip == sb.is_clip {continue}
			if sb.max_y < sa.min_y || sb.min_y > sa.max_y {continue}

			if px, py, ta, tb, hit := vatti_seg_intersect(sa, sb); hit {
				if ta > 1e-9 && ta < 1.0 - 1e-9 {
					append(&flat_splits, Flat_Split{seg_idx = i, t = ta, px = px, py = py})
					has_split[i] = true
				}
				if tb > 1e-9 && tb < 1.0 - 1e-9 {
					append(&flat_splits, Flat_Split{seg_idx = j, t = tb, px = px, py = py})
					has_split[j] = true
				}
			} else if vatti_segs_collinear(sa, sb) {
				if vatti_maybe_split_flat(&flat_splits, i, sa, sb.ax, sb.ay) {has_split[i] = true}
				if vatti_maybe_split_flat(&flat_splits, i, sa, sb.bx, sb.by) {has_split[i] = true}
				if vatti_maybe_split_flat(&flat_splits, j, sb, sa.ax, sa.ay) {has_split[j] = true}
				if vatti_maybe_split_flat(&flat_splits, j, sb, sa.bx, sa.by) {has_split[j] = true}
			}
		}
	}

	// Build CSR lookup for split segments only when any splits occurred.
	split_offsets: []int
	split_items: []Vatti_Split
	if len(flat_splits) > 0 {
		split_counts := make([]int, n_segs, context.temp_allocator)
		for fs in flat_splits {split_counts[fs.seg_idx] += 1}
		split_offsets = make([]int, n_segs + 1, context.temp_allocator)
		for i in 0..<n_segs {split_offsets[i + 1] = split_offsets[i] + split_counts[i]}
		split_items = make([]Vatti_Split, len(flat_splits), context.temp_allocator)
		split_cur := make([]int, n_segs, context.temp_allocator)
		copy(split_cur, split_offsets[:n_segs])
		for fs in flat_splits {
			split_items[split_cur[fs.seg_idx]] = {t = fs.t, px = fs.px, py = fs.py}
			split_cur[fs.seg_idx] += 1
		}
	}

	// Build deduplicated atomic vertical/slanted edges (accumulating dw_subj, dw_clip) and horizontal edges.
	Edge_Key :: struct {x0, y0, x1, y1: i64}
	vert_map := make(map[Edge_Key]int, n_segs * 2, context.temp_allocator)
	verts := make([dynamic]Vatti_Atomic_Vert, 0, n_segs, context.temp_allocator)
	horiz_seen := make(map[Edge_Key]bool, n_segs / 4 + 8, context.temp_allocator)
	horizs := make([dynamic]Vatti_Atomic_Horiz, 0, n_segs / 4 + 8, context.temp_allocator)
	pts_scratch := make([dynamic]Vatti_Split, 0, 16, context.temp_allocator)

	add_atomic := proc(
		ax, ay, bx, by: i64,
		is_clip: bool,
		vert_map: ^map[Edge_Key]int,
		verts: ^[dynamic]Vatti_Atomic_Vert,
		horiz_seen: ^map[Edge_Key]bool,
		horizs: ^[dynamic]Vatti_Atomic_Horiz,
	) {
		if ax == bx && ay == by {return}
		if ay == by {
			x0, x1 := min(ax, bx), max(ax, bx)
			hk := Edge_Key{x0, ay, x1, ay}
			if hk not_in horiz_seen^ {
				horiz_seen^[hk] = true
				append(horizs, Vatti_Atomic_Horiz{x0 = x0, x1 = x1, y = ay})
			}
			return
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
		vk := Edge_Key{x0, y0, x1, y1}
		if idx, exists := vert_map^[vk]; exists {
			if is_clip {verts^[idx].dw_clip += dw} else {verts^[idx].dw_subj += dw}
		} else {
			idx = len(verts^)
			vert_map^[vk] = idx
			append(verts, Vatti_Atomic_Vert{
				x0      = x0,
				y0      = y0,
				x1      = x1,
				y1      = y1,
				slope   = f64(x1 - x0) / f64(y1 - y0),
				dw_subj = 0 if is_clip else dw,
				dw_clip = dw if is_clip else 0,
			})
		}
	}

	for i in 0..<n_segs {
		s := all_segs[i]
		if !has_split[i] {
			add_atomic(s.ax, s.ay, s.bx, s.by, s.is_clip, &vert_map, &verts, &horiz_seen, &horizs)
			continue
		}
		clear(&pts_scratch)
		append(&pts_scratch, Vatti_Split{t = 0.0, px = s.ax, py = s.ay})
		for sp in split_items[split_offsets[i]:split_offsets[i + 1]] {
			append(&pts_scratch, sp)
		}
		append(&pts_scratch, Vatti_Split{t = 1.0, px = s.bx, py = s.by})
		slice.sort_by(pts_scratch[:], proc(a, b: Vatti_Split) -> bool {return a.t < b.t})

		for k in 0..<len(pts_scratch)-1 {
			add_atomic(pts_scratch[k].px, pts_scratch[k].py, pts_scratch[k + 1].px, pts_scratch[k + 1].py, s.is_clip, &vert_map, &verts, &horiz_seen, &horizs)
		}
	}

	if len(verts) == 0 {return {}, .None}

	// Step 3: Build sorted unique scanbeam Y coordinates.
	raw_ys := make([dynamic]i64, 0, len(verts)*2 + len(horizs), context.temp_allocator)
	for v in verts {
		append(&raw_ys, v.y0)
		append(&raw_ys, v.y1)
	}
	for h in horizs {
		append(&raw_ys, h.y)
	}
	slice.sort(raw_ys[:])
	ys := make([dynamic]i64, 0, len(raw_ys), context.temp_allocator)
	for y in raw_ys {
		if len(ys) == 0 || ys[len(ys)-1] != y {
			append(&ys, y)
		}
	}
	num_y := len(ys)
	if num_y < 2 {return {}, .None}

	// Bucket vertical edges by starting scanbeam s0, and horizontal edges by y index using flat CSR arrays.
	start_counts := make([]int, num_y, context.temp_allocator)
	for &v in verts {
		v.s0 = vatti_find_y(ys[:], v.y0)
		v.s1 = vatti_find_y(ys[:], v.y1)
		start_counts[v.s0] += 1
	}
	start_offsets := make([]int, num_y + 1, context.temp_allocator)
	for i in 0..<num_y {start_offsets[i + 1] = start_offsets[i] + start_counts[i]}
	start_items := make([]int, len(verts), context.temp_allocator)
	start_cursor := make([]int, num_y, context.temp_allocator)
	copy(start_cursor, start_offsets[:num_y])
	for v, vi in verts {
		start_items[start_cursor[v.s0]] = vi
		start_cursor[v.s0] += 1
	}

	horiz_counts := make([]int, num_y, context.temp_allocator)
	horiz_sy := make([]int, len(horizs), context.temp_allocator)
	for h, hi in horizs {
		sy := vatti_find_y(ys[:], h.y)
		horiz_sy[hi] = sy
		horiz_counts[sy] += 1
	}
	horiz_offsets := make([]int, num_y + 1, context.temp_allocator)
	for i in 0..<num_y {horiz_offsets[i + 1] = horiz_offsets[i] + horiz_counts[i]}
	horiz_items := make([]int, len(horizs), context.temp_allocator)
	horiz_cursor := make([]int, num_y, context.temp_allocator)
	copy(horiz_cursor, horiz_offsets[:num_y])
	for hi in 0..<len(horizs) {
		sy := horiz_sy[hi]
		horiz_items[horiz_cursor[sy]] = hi
		horiz_cursor[sy] += 1
	}

	// Sweep slabs s = 0 ..< num_y - 1 maintaining Active Edge Table (AET).
	active := make([dynamic]int, 0, 64, context.temp_allocator)
	prev_slab := make([dynamic]Slab_Interval, 0, 64, context.temp_allocator)
	cur_slab := make([dynamic]Slab_Interval, 0, 64, context.temp_allocator)
	kept_edges := make([dynamic]Vatti_Dir_Edge, 0, len(verts) + len(horizs), context.temp_allocator)

	Active_Sort :: struct {idx: int, x_mid: f64, slope: f64}
	aet_sort := make([dynamic]Active_Sort, 0, 64, context.temp_allocator)

	need_slab_intervals := len(horizs) > 0
	for s in 0..<num_y {
		// Flush any expiring edges (s1 == s) before removing them from active.
		w := 0
		for ei in active {
			v := &verts[ei]
			if v.s1 <= s {
				if v.run_verdict != 0 {
					vatti_emit_vert_run(&kept_edges, v^, ys[:], v.run_s_start, s, v.run_verdict)
					v.run_verdict = 0
				}
			} else {
				active[w] = ei
				w += 1
			}
		}
		resize(&active, w)

		// Build cur_slab for [ys[s], ys[s+1]] if s + 1 < num_y.
		has_horiz_here := horiz_offsets[s] < horiz_offsets[s + 1]
		has_horiz_next := s + 1 < num_y && horiz_offsets[s + 1] < horiz_offsets[s + 2]
		record_slab := need_slab_intervals && (has_horiz_here || has_horiz_next)
		clear(&cur_slab)
		if s + 1 < num_y {
			for ei in start_items[start_offsets[s]:start_offsets[s + 1]] {
				append(&active, ei)
			}

			if len(active) > 0 {
				y_mid := 0.5 * f64(ys[s] + ys[s + 1])
				clear(&aet_sort)
				for ei in active {
					v := verts[ei]
					xm := f64(v.x0) + v.slope * (y_mid - f64(v.y0))
					append(&aet_sort, Active_Sort{idx = ei, x_mid = xm, slope = v.slope})
				}
				// Insertion sort on nearly-sorted AET (O(k) in the common non-crossing case).
				for ai := 1; ai < len(aet_sort); ai += 1 {
					key := aet_sort[ai]
					aj := ai - 1
					for aj >= 0 && (aet_sort[aj].x_mid > key.x_mid ||
					    (aet_sort[aj].x_mid == key.x_mid && aet_sort[aj].slope > key.slope)) {
						aet_sort[aj + 1] = aet_sort[aj]
						aj -= 1
					}
					aet_sort[aj + 1] = key
				}
				// Persist sorted order back into `active` so the next slab starts sorted.
				for item, ai in aet_sort {active[ai] = item.idx}

				w_subj: i32 = 0
				w_clip: i32 = 0
				in_prev := vatti_bool_eval(
					vatti_fill_inside(w_subj, fill_rule),
					vatti_fill_inside(w_clip, fill_rule),
					operation,
				)
				for item in aet_sort {
					v := &verts[item.idx]
					w_subj += v.dw_subj
					w_clip += v.dw_clip
					in_next := vatti_bool_eval(
						vatti_fill_inside(w_subj, fill_rule),
						vatti_fill_inside(w_clip, fill_rule),
						operation,
					)
					if record_slab {
						x_bot := f64(v.x0) + item.slope * f64(ys[s] - v.y0)
						x_top := f64(v.x0) + item.slope * f64(ys[s + 1] - v.y0)
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

		// Classify horizontal edges lying on scanbeam ys[s] using prev_slab (at top of slab s-1)
		// vs cur_slab (at bottom of slab s).
		if has_horiz_here {
			for hi in horiz_items[horiz_offsets[s]:horiz_offsets[s + 1]] {
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

		// Swap prev_slab <-> cur_slab in O(1) without copying.
		if need_slab_intervals {
			prev_slab, cur_slab = cur_slab, prev_slab
		}
	}

	if len(kept_edges) == 0 {return {}, .None}

	raw_loops := vatti_trace_loops(kept_edges[:], context.temp_allocator)
	if len(raw_loops) == 0 {return {}, .None}
	return vatti_canonicalize_loops(raw_loops, limits, allocator)
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
	xb := v.x0 if s_start == v.s0 else v.x0 + i64(math.round(f64(v.x1 - v.x0) * f64(yb - v.y0) / f64(v.y1 - v.y0)))
	xt := v.x1 if s_end == v.s1 else v.x0 + i64(math.round(f64(v.x1 - v.x0) * f64(yt - v.y0) / f64(v.y1 - v.y0)))
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
vatti_seg_intersect :: proc(a, b: Vatti_Seg) -> (px, py: i64, ta, tb: f64, hit: bool) {
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
vatti_segs_collinear :: proc(a, b: Vatti_Seg) -> bool {
	dax := i128(a.bx - a.ax)
	day := i128(a.by - a.ay)
	return dax*i128(b.ax - a.ax) - day*i128(b.ay - a.ay) == 0 &&
	       dax*i128(b.bx - a.ax) - day*i128(b.by - a.ay) == 0
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
	slice.sort_by(entries, proc(a, b: Out_Entry) -> bool {
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
