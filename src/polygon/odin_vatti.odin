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
	x0, y0:  i64, // bottom (y0 < y1)
	x1, y1:  i64, // top
	slope:   f64, // (x1 - x0) / (y1 - y0), precomputed once
	dw_subj: i32, // +1 for downward subject edge (entering interior L->R), -1 for upward
	dw_clip: i32,
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

	// Fast path for non-self-intersecting Union with no crossings/overlaps.
	if first_pass_splits == 0 && operation == .Union && len(clips.paths) == 0 {
		if len(subjects.paths) == 1 {
			area := polygon_path_area_2(subjects.points)
			if area == 0 {return {}, .None}
			if fill_rule == .Positive && area < 0 {return {}, .None}
			if fill_rule == .Negative && area > 0 {return {}, .None}
			if area > 0 {
				return vatti_canonicalize_set(subjects, limits, allocator)
			}
		} else if len(segs) == len(all_segs) && len(subjects.paths) <= 64 && (fill_rule == .Positive || fill_rule == .Non_Zero) {
			// Clean non-intersecting outer ring(s) with optional pairwise-disjoint holes strictly
			// inside a single outer ring: skip the scanbeam sweep completely.
			bboxes: [64][4]i64
			is_pos: [64]bool
			valid := true
			pos_count := 0
			for p, pi in subjects.paths {
				s := int(p.offset)
				n := int(p.count)
				if n < 3 {valid = false; break}
				ring := subjects.points[s:s + n]
				area := polygon_path_area_2(ring)
				if area == 0 {valid = false; break}
				is_pos[pi] = area > 0
				if area > 0 {pos_count += 1}
				min_x, max_x := i64(ring[0].x), i64(ring[0].x)
				min_y, max_y := i64(ring[0].y), i64(ring[0].y)
				for pt in ring[1:] {
					x, y := i64(pt.x), i64(pt.y)
					if x < min_x {min_x = x}
					if x > max_x {max_x = x}
					if y < min_y {min_y = y}
					if y > max_y {max_y = y}
				}
				bboxes[pi] = {min_x, min_y, max_x, max_y}
			}
			if valid && pos_count > 0 {
				// All positive rings must be strictly bbox-disjoint from each other, and all
				// negative rings must be strictly bbox-disjoint from each other.
				n_paths := len(subjects.paths)
				for pi in 0..<n_paths {
					bi := bboxes[pi]
					for pj in (pi + 1)..<n_paths {
						if is_pos[pi] != is_pos[pj] {continue}
						bj := bboxes[pj]
						if !(bi[2] < bj[0] || bj[2] < bi[0] || bi[3] < bj[1] || bj[3] < bi[1]) {
							valid = false
							break
						}
					}
					if !valid {break}
				}
				// Every negative ring must lie strictly inside exactly one positive ring's bbox
				// and pass an exact point-in-polygon check against that positive ring.
				if valid && pos_count < n_paths {
					for hi in 0..<n_paths {
						if is_pos[hi] {continue}
						hb := bboxes[hi]
						hpt := subjects.points[int(subjects.paths[hi].offset)]
						containers := 0
						for oi in 0..<n_paths {
							if !is_pos[oi] {continue}
							ob := bboxes[oi]
							if hb[0] > ob[0] && hb[2] < ob[2] && hb[1] > ob[1] && hb[3] < ob[3] {
								op := subjects.paths[oi]
								oring := subjects.points[int(op.offset):int(op.offset) + int(op.count)]
								if vatti_point_in_ring(i64(hpt.x), i64(hpt.y), oring) {
									containers += 1
								}
							}
						}
						if containers != 1 {
							valid = false
							break
						}
					}
				}
				if valid {
					return vatti_canonicalize_set(subjects, limits, allocator)
				}
			}
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

	// Sort vertical edges by (y0, x0, y1, x1) and merge coincident edges in-place.
	// Radix-sort by y0 in O(N), then insertion-sort only the tiny equal-y0 runs by (x0, y1, x1).
	if radix_sort_by_i64(verts[:], proc(v: Vatti_Atomic_Vert) -> i64 {return v.y0}) {
		nv_raw := len(verts)
		rs := 0
		for rs < nv_raw {
			re := rs + 1
			y_run := verts[rs].y0
			for re < nv_raw && verts[re].y0 == y_run {re += 1}
			if re - rs > 1 {
				for a := rs + 1; a < re; a += 1 {
					key := verts[a]
					b := a - 1
					for b >= rs && (verts[b].x0 > key.x0 ||
					    (verts[b].x0 == key.x0 && (verts[b].y1 > key.y1 ||
					    (verts[b].y1 == key.y1 && verts[b].x1 > key.x1)))) {
						verts[b + 1] = verts[b]
						b -= 1
					}
					verts[b + 1] = key
				}
			}
			rs = re
		}
	} else {
		fast_sort(verts[:], proc(a, b: Vatti_Atomic_Vert) -> bool {
			if a.y0 != b.y0 {return a.y0 < b.y0}
			if a.x0 != b.x0 {return a.x0 < b.x0}
			if a.y1 != b.y1 {return a.y1 < b.y1}
			return a.x1 < b.x1
		})
	}
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
	// `verts` is already sorted by `y0` and `horizs` is already sorted by `y`, so only `y1` needs
	// sorting; a 3-way merge produces unique sorted `ys` with half the sort work.
	y1s := make_temp_non_zeroed(i64, len(verts))
	for v, vi in verts {y1s[vi] = v.y1}
	radix_sort_i64(y1s)
	ys := make([dynamic]i64, 0, len(verts) + len(horizs) + 8, context.temp_allocator)
	i0, i1, ih := 0, 0, 0
	nv, nh := len(verts), len(horizs)
	for i0 < nv || i1 < nv || ih < nh {
		y_min := max(i64)
		if i0 < nv && verts[i0].y0 < y_min {y_min = verts[i0].y0}
		if i1 < nv && y1s[i1] < y_min {y_min = y1s[i1]}
		if ih < nh && horizs[ih].y < y_min {y_min = horizs[ih].y}
		if len(ys) == 0 || ys[len(ys) - 1] != y_min {
			append(&ys, y_min)
		}
		for i0 < nv && verts[i0].y0 == y_min {i0 += 1}
		for i1 < nv && y1s[i1] == y_min {i1 += 1}
		for ih < nh && horizs[ih].y == y_min {ih += 1}
	}
	num_y := len(ys)
	if num_y < 2 {return {}, .None}

	Active_Entry :: struct {
		x_mid:       f64,
		slope:       f64,
		x0_f:        f64,
		y0_f:        f64,
		y1:          i64,
		idx:         i32,
		dw_subj:     i32,
		dw_clip:     i32,
		run_s_start: i32,
		run_verdict: i8,
	}
	aet := make([dynamic]Active_Entry, 0, 64, context.temp_allocator)
	prev_slab := make([dynamic]Slab_Interval, 0, 64, context.temp_allocator)
	cur_slab := make([dynamic]Slab_Interval, 0, 64, context.temp_allocator)
	kept_edges := make([dynamic]Vatti_Dir_Edge, 0, len(verts) + len(horizs), context.temp_allocator)

	need_slab_intervals := len(horizs) > 0
	next_vert := 0
	next_horiz := 0
	in_zero := vatti_bool_eval(
		vatti_fill_inside(0, fill_rule),
		vatti_fill_inside(0, fill_rule),
		operation,
	)
	fast_mode: u8 = 0
	if fill_rule == .Non_Zero {
		switch operation {
		case .Difference:   fast_mode = 1
		case .Intersection: fast_mode = 2
		case .Union:        fast_mode = 3
		case .Xor, .Invalid:
		}
	} else if fill_rule == .Positive && operation == .Union {
		fast_mode = 4
	}
	for s in 0..<num_y {
		y_cur := ys[s]
		has_next_slab := s + 1 < num_y
		has_new_vert := has_next_slab && next_vert < len(verts) && verts[next_vert].y0 == y_cur
		y_mid := 0.5 * f64(y_cur + ys[s + 1]) if has_new_vert else 0.0

		// Fused expire-flush + conditional x_mid update (only needed when new edges enter at y_cur).
		w := 0
		surviving_unsorted := false
		need_sort := false
		prev_x := -1.0e300
		prev_slope := -1.0e300
		if has_new_vert {
			for ai in 0..<len(aet) {
				e := &aet[ai]
				if e.y1 <= y_cur {
					if e.run_verdict != 0 {
						vatti_emit_vert_run(&kept_edges, verts[e.idx], ys[:], int(e.run_s_start), s, e.run_verdict)
					}
				} else {
					xm := e.x0_f + e.slope * (y_mid - e.y0_f)
					e.x_mid = xm
					if w > 0 && (prev_x > xm || (prev_x == xm && prev_slope > e.slope)) {
						surviving_unsorted = true
						need_sort = true
					}
					prev_x = xm
					prev_slope = e.slope
					if w != ai {aet[w] = e^}
					w += 1
				}
			}
		} else {
			for ai in 0..<len(aet) {
				e := &aet[ai]
				if e.y1 <= y_cur {
					if e.run_verdict != 0 {
						vatti_emit_vert_run(&kept_edges, verts[e.idx], ys[:], int(e.run_s_start), s, e.run_verdict)
					}
				} else {
					if w != ai {aet[w] = e^}
					w += 1
				}
			}
		}
		resize(&aet, w)
		existing_count := w

		h_start := next_horiz
		for next_horiz < len(horizs) && horizs[next_horiz].y == y_cur {
			next_horiz += 1
		}
		has_horiz_here := h_start < next_horiz
		has_horiz_next := next_horiz < len(horizs) && has_next_slab && horizs[next_horiz].y == ys[s + 1]
		record_slab := need_slab_intervals && (has_horiz_here || has_horiz_next)
		clear(&cur_slab)

		if has_next_slab {
			if has_new_vert {
				for next_vert < len(verts) && verts[next_vert].y0 == y_cur {
					v := verts[next_vert]
					x0_f := f64(v.x0)
					y0_f := f64(v.y0)
					xm := x0_f + v.slope * (y_mid - y0_f)
					if len(aet) > 0 && (prev_x > xm || (prev_x == xm && prev_slope > v.slope)) {
						need_sort = true
					}
					prev_x = xm
					prev_slope = v.slope
					append(&aet, Active_Entry{
						x_mid   = xm,
						slope   = v.slope,
						x0_f    = x0_f,
						y0_f    = y0_f,
						y1      = v.y1,
						idx     = i32(next_vert),
						dw_subj = v.dw_subj,
						dw_clip = v.dw_clip,
					})
					next_vert += 1
				}
			}

			if len(aet) > 0 {
				if need_sort {
					// Insertion sort: when surviving edges stayed ordered, only insert the newly entered tail.
					sort_start := 1 if surviving_unsorted else max(1, existing_count)
					for ai := sort_start; ai < len(aet); ai += 1 {
						key := aet[ai]
						aj := ai - 1
						for aj >= 0 && (aet[aj].x_mid > key.x_mid ||
						    (aet[aj].x_mid == key.x_mid && aet[aj].slope > key.slope)) {
							aet[aj + 1] = aet[aj]
							aj -= 1
						}
						aet[aj + 1] = key
					}
				}

				w_subj: i32 = 0
				w_clip: i32 = 0
				in_prev := in_zero
				if !record_slab {
					switch fast_mode {
					case 1: // Difference + Non_Zero
						for &e in aet {
							w_subj += e.dw_subj
							w_clip += e.dw_clip
							in_next := w_subj != 0 && w_clip == 0
							slab_verdict: i8 = (+1 if in_prev else -1) if in_prev != in_next else 0
							if slab_verdict != e.run_verdict {
								if e.run_verdict != 0 {
									vatti_emit_vert_run(&kept_edges, verts[e.idx], ys[:], int(e.run_s_start), s, e.run_verdict)
								}
								e.run_verdict = slab_verdict
								e.run_s_start = i32(s)
							}
							in_prev = in_next
						}
					case 2: // Intersection + Non_Zero
						for &e in aet {
							w_subj += e.dw_subj
							w_clip += e.dw_clip
							in_next := w_subj != 0 && w_clip != 0
							slab_verdict: i8 = (+1 if in_prev else -1) if in_prev != in_next else 0
							if slab_verdict != e.run_verdict {
								if e.run_verdict != 0 {
									vatti_emit_vert_run(&kept_edges, verts[e.idx], ys[:], int(e.run_s_start), s, e.run_verdict)
								}
								e.run_verdict = slab_verdict
								e.run_s_start = i32(s)
							}
							in_prev = in_next
						}
					case 3: // Union + Non_Zero
						for &e in aet {
							w_subj += e.dw_subj
							w_clip += e.dw_clip
							in_next := w_subj != 0 || w_clip != 0
							slab_verdict: i8 = (+1 if in_prev else -1) if in_prev != in_next else 0
							if slab_verdict != e.run_verdict {
								if e.run_verdict != 0 {
									vatti_emit_vert_run(&kept_edges, verts[e.idx], ys[:], int(e.run_s_start), s, e.run_verdict)
								}
								e.run_verdict = slab_verdict
								e.run_s_start = i32(s)
							}
							in_prev = in_next
						}
					case 4: // Union + Positive
						for &e in aet {
							w_subj += e.dw_subj
							w_clip += e.dw_clip
							in_next := w_subj > 0 || w_clip > 0
							slab_verdict: i8 = (+1 if in_prev else -1) if in_prev != in_next else 0
							if slab_verdict != e.run_verdict {
								if e.run_verdict != 0 {
									vatti_emit_vert_run(&kept_edges, verts[e.idx], ys[:], int(e.run_s_start), s, e.run_verdict)
								}
								e.run_verdict = slab_verdict
								e.run_s_start = i32(s)
							}
							in_prev = in_next
						}
					case:
						for &e in aet {
							w_subj += e.dw_subj
							w_clip += e.dw_clip
							in_next := vatti_bool_eval(
								vatti_fill_inside(w_subj, fill_rule),
								vatti_fill_inside(w_clip, fill_rule),
								operation,
							)
							slab_verdict: i8 = (+1 if in_prev else -1) if in_prev != in_next else 0
							if slab_verdict != e.run_verdict {
								if e.run_verdict != 0 {
									vatti_emit_vert_run(&kept_edges, verts[e.idx], ys[:], int(e.run_s_start), s, e.run_verdict)
								}
								e.run_verdict = slab_verdict
								e.run_s_start = i32(s)
							}
							in_prev = in_next
						}
					}
				} else {
					y_cur_f := f64(y_cur)
					y_top_f := f64(ys[s + 1])
					for &e in aet {
						w_subj += e.dw_subj
						w_clip += e.dw_clip
						in_next: bool
						switch fast_mode {
						case 1: in_next = w_subj != 0 && w_clip == 0
						case 2: in_next = w_subj != 0 && w_clip != 0
						case 3: in_next = w_subj != 0 || w_clip != 0
						case 4: in_next = w_subj > 0 || w_clip > 0
						case:
							in_next = vatti_bool_eval(
								vatti_fill_inside(w_subj, fill_rule),
								vatti_fill_inside(w_clip, fill_rule),
								operation,
							)
						}
						x_bot := e.x0_f + e.slope * (y_cur_f - e.y0_f)
						x_top := e.x0_f + e.slope * (y_top_f - e.y0_f)
						append(&cur_slab, Slab_Interval{x_bot = x_bot, x_top = x_top, in_res = in_next})

						slab_verdict: i8 = (+1 if in_prev else -1) if in_prev != in_next else 0
						if slab_verdict != e.run_verdict {
							if e.run_verdict != 0 {
								vatti_emit_vert_run(&kept_edges, verts[e.idx], ys[:], int(e.run_s_start), s, e.run_verdict)
							}
							e.run_verdict = slab_verdict
							e.run_s_start = i32(s)
						}
						in_prev = in_next
					}
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
	Seg_Ord_32 :: struct {
		min_x: i32,
		min_y: i32,
		max_y: i32,
		idx:   i32,
	}
	Seg_Ord :: struct {
		min_x: i64,
		min_y: i64,
		max_y: i64,
		idx:   i32,
	}
	SNAP_I32_LIMIT :: i64(1_000_000_000)
	fits_i32 := true
	for s in segs {
		if s.min_x < -SNAP_I32_LIMIT || s.max_x > SNAP_I32_LIMIT ||
		   s.min_y < -SNAP_I32_LIMIT || s.max_y > SNAP_I32_LIMIT {
			fits_i32 = false
			break
		}
	}
	seg_ords_32: []Seg_Ord_32
	seg_ords: []Seg_Ord
	if fits_i32 {
		seg_ords_32 = make_temp_non_zeroed(Seg_Ord_32, n_segs)
		for i in 0..<n_segs {
			s := segs[i]
			seg_ords_32[i] = {min_x = i32(s.min_x), min_y = i32(s.min_y), max_y = i32(s.max_y), idx = i32(i)}
		}
		if !radix_sort_by_i64(seg_ords_32, proc(o: Seg_Ord_32) -> i64 {return i64(o.min_x)}) {
			fast_sort(seg_ords_32, proc(a, b: Seg_Ord_32) -> bool {return a.min_x < b.min_x})
		}
	} else {
		seg_ords = make_temp_non_zeroed(Seg_Ord, n_segs)
		for i in 0..<n_segs {
			s := segs[i]
			seg_ords[i] = {min_x = s.min_x, min_y = s.min_y, max_y = s.max_y, idx = i32(i)}
		}
		fast_sort(seg_ords, proc(a, b: Seg_Ord) -> bool {return a.min_x < b.min_x})
	}

	// Hot pixels are every endpoint and every rounded proper intersection. Endpoint pixels are
	// tested in the same pair sweep that finds intersections (a segment passing within one unit of
	// another segment's endpoint has an overlapping widened box); intersection pixels are few and
	// are looked up per segment afterwards.
	Snap_Item :: struct {seg: int, t: f64, x, y: i64}
	snaps := make([dynamic]Snap_Item, 0, 64, context.temp_allocator)
	try_snap :: #force_inline proc(snaps: ^[dynamic]Snap_Item, idx: int, sg: ^Vatti_Seg, hx, hy: i64) {
		if (hx == sg.ax && hy == sg.ay) || (hx == sg.bx && hy == sg.by) {return}
		if hx < sg.min_x - 1 || hx > sg.max_x + 1 || hy < sg.min_y - 1 || hy > sg.max_y + 1 {return}
		// Exact integer line-to-unit-square pre-filter: a point in [-0.5, 0.5]^2 around h satisfies
		// |(h.x - ax)*dy - (h.y - ay)*dx| <= 0.5*(|dx| + |dy|), rejecting ~99% of misses with no division.
		dx_i := sg.bx - sg.ax
		dy_i := sg.by - sg.ay
		adx := abs(dx_i)
		ady := abs(dy_i)
		if adx < 1_000_000_000 && ady < 1_000_000_000 {
			cross := (hx - sg.ax)*dy_i - (hy - sg.ay)*dx_i
			if 2*abs(cross) > adx + ady {return}
		}
		if !vatti_segment_hits_pixel(sg^, {hx, hy}) {return}
		dx := f64(dx_i)
		dy := f64(dy_i)
		t := (f64(hx - sg.ax)*dx + f64(hy - sg.ay)*dy) / (dx*dx + dy*dy)
		append(snaps, Snap_Item{idx, t, hx, hy})
	}
	hot := make([dynamic][2]i64, 0, 16, context.temp_allocator)
	if fits_i32 {
		did_snap_strips := false
		if n_segs >= 64 {
			g_min_y := seg_ords_32[0].min_y
			g_max_y := seg_ords_32[0].max_y
			for oi in 1..<n_segs {
				o := seg_ords_32[oi]
				if o.min_y < g_min_y {g_min_y = o.min_y}
				if o.max_y > g_max_y {g_max_y = o.max_y}
			}
			y_span := i64(g_max_y) - i64(g_min_y) + 2
			if y_span > 0 {
				n_strips := clamp(n_segs / 16, 4, 64)
				Strip_Entry :: struct {
					min_x: i32,
					min_y: i32,
					max_y: i32,
					idx:   i32,
					s0:    i32,
				}
				inv_span := f64(n_strips) / f64(y_span)
				base_y := i64(g_min_y) - 1
				counts: [64]int
				s0s := make_temp_non_zeroed(i32, n_segs)
				s1s := make_temp_non_zeroed(i32, n_segs)
				total_entries := 0
				for oi in 0..<n_segs {
					o := seg_ords_32[oi]
					s0 := clamp(int(f64(i64(o.min_y) - 1 - base_y) * inv_span), 0, n_strips - 1)
					s1 := clamp(int(f64(i64(o.max_y) + 1 - base_y) * inv_span), 0, n_strips - 1)
					s0s[oi] = i32(s0)
					s1s[oi] = i32(s1)
					for s in s0..=s1 {counts[s] += 1}
					total_entries += s1 - s0 + 1
				}
				offsets: [65]int
				for s in 0..<n_strips {offsets[s + 1] = offsets[s] + counts[s]}
				cursors := offsets
				strip_data := make_temp_non_zeroed(Strip_Entry, total_entries)
				for oi in 0..<n_segs {
					o := seg_ords_32[oi]
					s0 := int(s0s[oi])
					s1 := int(s1s[oi])
					ent := Strip_Entry{min_x = o.min_x, min_y = o.min_y, max_y = o.max_y, idx = o.idx, s0 = i32(s0)}
					for s in s0..=s1 {
						strip_data[cursors[s]] = ent
						cursors[s] += 1
					}
				}
				for s in 0..<n_strips {
					st := strip_data[offsets[s]:offsets[s + 1]]
					n_st := len(st)
					s_i32 := i32(s)
					for ai in 0..<n_st {
						ord_i := st[ai]
						i := int(ord_i.idx)
						sa := &segs[i]
						sa_max_x_1 := i32(sa.max_x + 1)
						sa_min_y_1 := i32(sa.min_y - 1)
						sa_max_y_1 := i32(sa.max_y + 1)
						for aj := ai + 1; aj < n_st; aj += 1 {
							ord_j := st[aj]
							if ord_j.min_x > sa_max_x_1 {break}
							if ord_j.max_y < sa_min_y_1 || ord_j.min_y > sa_max_y_1 {continue}
							if max(ord_i.s0, ord_j.s0) != s_i32 {continue}
							j := int(ord_j.idx)
							sb := &segs[j]
							try_snap(&snaps, i, sa, sb.ax, sb.ay)
							try_snap(&snaps, i, sa, sb.bx, sb.by)
							try_snap(&snaps, j, sb, sa.ax, sa.ay)
							try_snap(&snaps, j, sb, sa.bx, sa.by)
							if sb.min_x > sa.max_x || sb.max_y < sa.min_y || sb.min_y > sa.max_y {continue}
							if skip_same_set && sa.is_clip == sb.is_clip {continue}
							shared := (sa.ax == sb.ax && sa.ay == sb.ay) || (sa.ax == sb.bx && sa.ay == sb.by) ||
							          (sa.bx == sb.ax && sa.by == sb.ay) || (sa.bx == sb.bx && sa.by == sb.by)
							if !shared {
								if px, py, ta, tb, hit := vatti_seg_intersect_i64(sa, sb); hit {
									if (ta > 1e-9 && ta < 1.0 - 1e-9) || (tb > 1e-9 && tb < 1.0 - 1e-9) {
										append(&hot, [2]i64{px, py})
										crossings += 1
									}
									continue
								}
							}
							if vatti_segs_collinear_i64(sa, sb) &&
							   max(sa.min_x, sb.min_x) <= min(sa.max_x, sb.max_x) &&
							   max(sa.min_y, sb.min_y) <= min(sa.max_y, sb.max_y) {
								crossings += 1
							}
						}
					}
				}
				did_snap_strips = true
			}
		}
		if !did_snap_strips {
			for oi in 0..<n_segs {
				i := int(seg_ords_32[oi].idx)
				sa := &segs[i]
				sa_max_x_1 := i32(sa.max_x + 1)
				sa_min_y_1 := i32(sa.min_y - 1)
				sa_max_y_1 := i32(sa.max_y + 1)
				for oj := oi + 1; oj < n_segs; oj += 1 {
					ord_j := seg_ords_32[oj]
					if ord_j.min_x > sa_max_x_1 {break}
					if ord_j.max_y < sa_min_y_1 || ord_j.min_y > sa_max_y_1 {continue}
					j := int(ord_j.idx)
					sb := &segs[j]
					try_snap(&snaps, i, sa, sb.ax, sb.ay)
					try_snap(&snaps, i, sa, sb.bx, sb.by)
					try_snap(&snaps, j, sb, sa.ax, sa.ay)
					try_snap(&snaps, j, sb, sa.bx, sa.by)
					if sb.min_x > sa.max_x || sb.max_y < sa.min_y || sb.min_y > sa.max_y {continue}
					if skip_same_set && sa.is_clip == sb.is_clip {continue}
					shared := (sa.ax == sb.ax && sa.ay == sb.ay) || (sa.ax == sb.bx && sa.ay == sb.by) ||
					          (sa.bx == sb.ax && sa.by == sb.ay) || (sa.bx == sb.bx && sa.by == sb.by)
					if !shared {
						if px, py, ta, tb, hit := vatti_seg_intersect_i64(sa, sb); hit {
							if (ta > 1e-9 && ta < 1.0 - 1e-9) || (tb > 1e-9 && tb < 1.0 - 1e-9) {
								append(&hot, [2]i64{px, py})
								crossings += 1
							}
							continue
						}
					}
					if vatti_segs_collinear_i64(sa, sb) &&
					   max(sa.min_x, sb.min_x) <= min(sa.max_x, sb.max_x) &&
					   max(sa.min_y, sb.min_y) <= min(sa.max_y, sb.max_y) {
						crossings += 1
					}
				}
			}
		}
	} else {
		for oi in 0..<n_segs {
			i := int(seg_ords[oi].idx)
			sa := &segs[i]
			sa_max_x_1 := sa.max_x + 1
			sa_min_y_1 := sa.min_y - 1
			sa_max_y_1 := sa.max_y + 1
			for oj := oi + 1; oj < n_segs; oj += 1 {
				ord_j := seg_ords[oj]
				if ord_j.min_x > sa_max_x_1 {break}
				if ord_j.max_y < sa_min_y_1 || ord_j.min_y > sa_max_y_1 {continue}
				j := int(ord_j.idx)
				sb := &segs[j]
				try_snap(&snaps, i, sa, sb.ax, sb.ay)
				try_snap(&snaps, i, sa, sb.bx, sb.by)
				try_snap(&snaps, j, sb, sa.ax, sa.ay)
				try_snap(&snaps, j, sb, sa.bx, sa.by)
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
		for &sg, i in segs {
			lo, hi := 0, len(hot)
			for lo < hi {
				mid := (lo + hi) / 2
				if hot[mid][0] < sg.min_x - 1 {lo = mid + 1} else {hi = mid}
			}
			for k := lo; k < len(hot) && hot[k][0] <= sg.max_x + 1; k += 1 {
				try_snap(&snaps, i, &sg, hot[k][0], hot[k][1])
			}
		}
	}
	if len(snaps) == 0 && crossings == 0 {
		pieces = make([dynamic]Vatti_Seg, 0, n_segs, context.temp_allocator)
		append(&pieces, ..segs)
		return
	}
	// O(M) bucket-sort snaps by `seg`, then insertion-sort each segment's tiny bucket by (t, x, y).
	snap_offsets := make([]int, n_segs + 1, context.temp_allocator)
	for sn in snaps {snap_offsets[sn.seg + 1] += 1}
	for i in 0..<n_segs {snap_offsets[i + 1] += snap_offsets[i]}
	snap_cursors := make_temp_non_zeroed(int, n_segs)
	copy(snap_cursors, snap_offsets[:n_segs])
	sorted_snaps := make_temp_non_zeroed(Snap_Item, len(snaps))
	for sn in snaps {
		pos := snap_cursors[sn.seg]
		sorted_snaps[pos] = sn
		snap_cursors[sn.seg] = pos + 1
	}
	for i in 0..<n_segs {
		s0, s1 := snap_offsets[i], snap_offsets[i + 1]
		if s1 - s0 <= 1 {continue}
		for a := s0 + 1; a < s1; a += 1 {
			key := sorted_snaps[a]
			b := a - 1
			for b >= s0 && (sorted_snaps[b].t > key.t ||
			    (sorted_snaps[b].t == key.t && (sorted_snaps[b].x > key.x ||
			    (sorted_snaps[b].x == key.x && sorted_snaps[b].y > key.y)))) {
				sorted_snaps[b + 1] = sorted_snaps[b]
				b -= 1
			}
			sorted_snaps[b + 1] = key
		}
	}

	// Route each segment through its hot pixels in order along the segment. Parents are visited
	// in min-x order, so the pieces come out nearly sorted by min-x.
	routed := make([dynamic]Vatti_Seg, 0, n_segs + len(snaps), context.temp_allocator)
	for oi in 0..<n_segs {
		i := int(seg_ords_32[oi].idx) if fits_i32 else int(seg_ords[oi].idx)
		sg := segs[i]
		px, py := sg.ax, sg.ay
		for sn in sorted_snaps[snap_offsets[i]:snap_offsets[i + 1]] {
			if sn.x == px && sn.y == py {continue}
			vatti_append_piece(&routed, px, py, sn.x, sn.y, sg.is_clip)
			px, py = sn.x, sn.y
		}
		vatti_append_piece(&routed, px, py, sg.bx, sg.by, sg.is_clip)
	}

	// Split collinear overlaps at the other piece's endpoints (exact points, no rounding).
	n_routed := len(routed)
	route_ords := make_temp_non_zeroed(Seg_Ord, n_routed)
	for i in 0..<n_routed {
		r := routed[i]
		route_ords[i] = {min_x = r.min_x, min_y = r.min_y, max_y = r.max_y, idx = i32(i)}
	}
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
	did_route_strips := false
	if fits_i32 && n_routed >= 64 {
		g_min_y := route_ords[0].min_y
		g_max_y := route_ords[0].max_y
		for oi in 1..<n_routed {
			o := route_ords[oi]
			if o.min_y < g_min_y {g_min_y = o.min_y}
			if o.max_y > g_max_y {g_max_y = o.max_y}
		}
		y_span := g_max_y - g_min_y + 1
		if y_span > 0 {
			n_strips := clamp(n_routed / 16, 4, 64)
			RStrip_Entry :: struct {
				min_x: i32,
				min_y: i32,
				max_y: i32,
				idx:   i32,
				s0:    i32,
			}
			inv_span := f64(n_strips) / f64(y_span)
			counts: [64]int
			s0s := make_temp_non_zeroed(i32, n_routed)
			s1s := make_temp_non_zeroed(i32, n_routed)
			total_entries := 0
			for oi in 0..<n_routed {
				o := route_ords[oi]
				s0 := clamp(int(f64(o.min_y - g_min_y) * inv_span), 0, n_strips - 1)
				s1 := clamp(int(f64(o.max_y - g_min_y) * inv_span), 0, n_strips - 1)
				s0s[oi] = i32(s0)
				s1s[oi] = i32(s1)
				for s in s0..=s1 {counts[s] += 1}
				total_entries += s1 - s0 + 1
			}
			offsets: [65]int
			for s in 0..<n_strips {offsets[s + 1] = offsets[s] + counts[s]}
			cursors := offsets
			strip_data := make_temp_non_zeroed(RStrip_Entry, total_entries)
			for oi in 0..<n_routed {
				o := route_ords[oi]
				s0 := int(s0s[oi])
				s1 := int(s1s[oi])
				ent := RStrip_Entry{min_x = i32(o.min_x), min_y = i32(o.min_y), max_y = i32(o.max_y), idx = o.idx, s0 = i32(s0)}
				for s in s0..=s1 {
					strip_data[cursors[s]] = ent
					cursors[s] += 1
				}
			}
			for s in 0..<n_strips {
				st := strip_data[offsets[s]:offsets[s + 1]]
				n_st := len(st)
				s_i32 := i32(s)
				for ai in 0..<n_st {
					ord_i := st[ai]
					i := int(ord_i.idx)
					sa := routed[i]
					sa_max_x := i32(sa.max_x)
					sa_min_y := i32(sa.min_y)
					sa_max_y := i32(sa.max_y)
					for aj := ai + 1; aj < n_st; aj += 1 {
						ord_j := st[aj]
						if ord_j.min_x > sa_max_x {break}
						if ord_j.max_y < sa_min_y || ord_j.min_y > sa_max_y {continue}
						if max(ord_i.s0, ord_j.s0) != s_i32 {continue}
						j := int(ord_j.idx)
						sb := &routed[j]
						if !vatti_segs_collinear_i64(&routed[i], sb) {continue}
						vatti_maybe_split_flat(&splits, i, sa, sb.ax, sb.ay)
						vatti_maybe_split_flat(&splits, i, sa, sb.bx, sb.by)
						vatti_maybe_split_flat(&splits, j, sb^, sa.ax, sa.ay)
						vatti_maybe_split_flat(&splits, j, sb^, sa.bx, sa.by)
					}
				}
			}
			did_route_strips = true
		}
	}
	if !did_route_strips {
		for oi in 0..<n_routed {
			i := int(route_ords[oi].idx)
			sa := routed[i]
			for oj := oi + 1; oj < n_routed; oj += 1 {
				ord_j := route_ords[oj]
				if ord_j.min_x > sa.max_x {break}
				if ord_j.max_y < sa.min_y || ord_j.min_y > sa.max_y {continue}
				j := int(ord_j.idx)
				sb := &routed[j]
				if !vatti_segs_collinear(&routed[i], sb) {continue}
				vatti_maybe_split_flat(&splits, i, sa, sb.ax, sb.ay)
				vatti_maybe_split_flat(&splits, i, sa, sb.bx, sb.by)
				vatti_maybe_split_flat(&splits, j, sb^, sa.ax, sa.ay)
				vatti_maybe_split_flat(&splits, j, sb^, sa.bx, sa.by)
			}
		}
	}
	pieces = make([dynamic]Vatti_Seg, 0, n_routed + len(splits), context.temp_allocator)
	if len(splits) == 0 {
		append(&pieces, ..routed[:])
		return
	}
	fast_sort(splits[:], proc(a, b: Flat_Split) -> bool {
		if a.seg_idx != b.seg_idx {return a.seg_idx < b.seg_idx}
		if a.t != b.t {return a.t < b.t}
		if a.px != b.px {return a.px < b.px}
		return a.py < b.py
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
vatti_point_in_ring :: proc(px, py: i64, ring: []Polygon_Point) -> bool {
	inside := false
	n := len(ring)
	j := n - 1
	for i in 0..<n {
		xi, yi := i64(ring[i].x), i64(ring[i].y)
		xj, yj := i64(ring[j].x), i64(ring[j].y)
		if (yi > py) != (yj > py) {
			// Compare px against x-intercept using exact integer cross product.
			dy := yj - yi
			lhs := i128(px - xi) * i128(dy)
			rhs := i128(xj - xi) * i128(py - yi)
			if (dy > 0 && lhs < rhs) || (dy < 0 && lhs > rhs) {
				inside = !inside
			}
		}
		j = i
	}
	return inside
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
vatti_seg_intersect_i64 :: #force_inline proc(a, b: ^Vatti_Seg) -> (px, py: i64, ta, tb: f64, hit: bool) {
	dax := a.bx - a.ax
	day := a.by - a.ay
	dbx := b.bx - b.ax
	dby := b.by - b.ay
	denom := dax*dby - day*dbx
	if denom == 0 {return 0, 0, 0, 0, false}
	rx := b.ax - a.ax
	ry := b.ay - a.ay
	num_a := rx*dby - ry*dbx
	num_b := rx*day - ry*dax
	if denom > 0 {
		if num_a < 0 || num_a > denom || num_b < 0 || num_b > denom {return 0, 0, 0, 0, false}
	} else {
		if num_a > 0 || num_a < denom || num_b > 0 || num_b < denom {return 0, 0, 0, 0, false}
	}
	inv_d := 1.0 / f64(denom)
	ta = f64(num_a) * inv_d
	tb = f64(num_b) * inv_d
	px = a.ax + i64(math.round(ta * f64(dax)))
	py = a.ay + i64(math.round(ta * f64(day)))
	return px, py, ta, tb, true
}

@(private = "file")
vatti_segs_collinear_i64 :: #force_inline proc(a, b: ^Vatti_Seg) -> bool {
	dax := a.bx - a.ax
	day := a.by - a.ay
	if dax*(b.ay - a.ay) - day*(b.ax - a.ax) != 0 {return false}
	return dax*(b.by - a.ay) - day*(b.bx - a.ax) == 0
}

@(private = "file")
vatti_seg_intersect :: #force_inline proc(a, b: ^Vatti_Seg) -> (px, py: i64, ta, tb: f64, hit: bool) {
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
vatti_segs_collinear :: #force_inline proc(a, b: ^Vatti_Seg) -> bool {
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

	// Flat power-of-2 open-addressing hash table mapping (ax, ay) -> head edge index + 1 (0 = empty),
	// with a parallel `next_same` linked-list array for multi-way junctions (O(N) build & lookup).
	cap_pow2 := 16
	for cap_pow2 < n * 2 {cap_pow2 <<= 1}
	mask := u64(cap_pow2 - 1)
	table := make([]i32, cap_pow2, context.temp_allocator)
	next_same := make([]i32, n, context.temp_allocator)

	hash_pt :: #force_inline proc(x, y: i64) -> u64 {
		h := u64(x) * 0x9e3779b97f4a7c15
		h ~= u64(y) * 0xbf58476d1ce4e5b9
		h ~= h >> 30
		h *= 0x94d049bb133111eb
		return h ~ (h >> 31)
	}

	for e, idx in edges {
		slot := hash_pt(e.ax, e.ay) & mask
		for {
			head := table[slot]
			if head == 0 {
				table[slot] = i32(idx + 1)
				break
			}
			he := edges[head - 1]
			if he.ax == e.ax && he.ay == e.ay {
				// Prepend into chain (or append? Multi-way junction picks minimum turn angle).
				next_same[idx] = head
				table[slot] = i32(idx + 1)
				break
			}
			slot = (slot + 1) & mask
		}
	}

	lookup_head :: #force_inline proc(table: []i32, edges: []Vatti_Dir_Edge, mask: u64, x, y: i64) -> i32 {
		slot := hash_pt(x, y) & mask
		for {
			head := table[slot]
			if head == 0 {return 0}
			he := edges[head - 1]
			if he.ax == x && he.ay == y {return head}
			slot = (slot + 1) & mask
		}
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
			head := lookup_head(table, edges, mask, nx, ny)
			if head == 0 {break}

			// Fast path (99.9% of vertices): single outgoing edge — skip atan2 completely.
			ci0 := int(head - 1)
			if next_same[ci0] == 0 {
				if edges[ci0].used {break}
				cur_idx = ci0
				continue
			}

			// Multi-way junction: pick tightest left turn.
			in_ang := math.atan2(f64(e.by - e.ay), f64(e.bx - e.ax))
			best_idx := -1
			best_turn := f64(1e9)
			for cur := head; cur != 0; cur = next_same[cur - 1] {
				ci := int(cur - 1)
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
				dx1 := i64(p_cur.x) - i64(p_prev.x)
				dy1 := i64(p_cur.y) - i64(p_prev.y)
				dx2 := i64(p_next.x) - i64(p_cur.x)
				dy2 := i64(p_next.y) - i64(p_cur.y)
				collinear: bool
				if abs(dx1) < VATTI_I64_SAFE_DELTA && abs(dy1) < VATTI_I64_SAFE_DELTA &&
				   abs(dx2) < VATTI_I64_SAFE_DELTA && abs(dy2) < VATTI_I64_SAFE_DELTA {
					collinear = dx1*dy2 - dy1*dx2 == 0
				} else {
					collinear = i128(dx1)*i128(dy2) - i128(dy1)*i128(dx2) == 0
				}
				if !collinear {
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
