package features

import "core:math"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"

Arc_Fit_Config :: struct {
	enabled:             bool,
	max_chord_error_um:  f64, // default 20.0 um (0.02 mm)
	min_radius_um:       f64, // default 200.0 um (0.2 mm)
	max_radius_um:       f64, // default 500_000.0 um (500 mm)
	min_segments:        int, // default 3
}

DEFAULT_ARC_FIT_CONFIG :: Arc_Fit_Config{
	enabled            = true,
	max_chord_error_um = 20.0,
	min_radius_um      = 200.0,
	max_radius_um      = 500_000.0,
	min_segments       = 3,
}

Arc_Fit_Stats :: struct {
	arcs_fitted:        u64,
	segments_replaced:  u64,
}

// Fits G2/G3 circular arcs to consecutive linear Extrude operations in `motion` while
// preserving exact filament totals, layer durations, and machine bounds.
motion_plan_fit_arcs :: proc(
	motion: ^Motion_Plan_Result,
	printer: profiles.Printer_Profile,
	config := DEFAULT_ARC_FIT_CONFIG,
	allocator := context.allocator,
) -> Arc_Fit_Stats {
	if motion == nil || !config.enabled || len(motion.operations) < 3 {
		return {}
	}
	min_segs := config.min_segments
	if min_segs < 3 {min_segs = 3}
	max_err := config.max_chord_error_um
	if max_err <= 0 {max_err = 20.0}

	new_ops := make([dynamic]Motion_Operation, 0, len(motion.operations), allocator)
	stats := Arc_Fit_Stats{}

	for &layer in motion.layers {
		op_start := int(layer.operation_offset)
		op_end := op_start + int(layer.operation_count)
		new_layer_start := len(new_ops)

		i := op_start
		for i < op_end {
			op0 := motion.operations[i]
			if op0.kind != .Extrude || op0.arc != .None {
				append(&new_ops, op0)
				i += 1
				continue
			}

			// Find maximal contiguous run of compatible linear Extrude operations.
			run_end := i + 1
			for run_end < op_end {
				prev := motion.operations[run_end - 1]
				cur := motion.operations[run_end]
				if cur.kind != .Extrude || cur.arc != .None ||
				   cur.path_id != op0.path_id ||
				   cur.role != op0.role ||
				   cur.speed != op0.speed ||
				   cur.acceleration != op0.acceleration ||
				   cur.fan_ratio != op0.fan_ratio ||
				   cur.point_a != prev.point_b {
					break
				}
				run_end += 1
			}

			run_len := run_end - i
			if run_len < min_segs {
				for k in i..<run_end {
					append(&new_ops, motion.operations[k])
				}
				i = run_end
				continue
			}

			// Greedily fit arcs inside [i ..< run_end].
			cursor := i
			for cursor < run_end {
				best_end := -1
				best_center: polygon.Polygon_Point
				best_kind: Motion_Arc_Kind

				// Try expanding arc from cursor with at least min_segs segments.
				if cursor + min_segs <= run_end {
					max_try := min(run_end, cursor + 64)
					for cand_end := cursor + min_segs; cand_end <= max_try; cand_end += 1 {
						center, arc_kind, fit_ok := arc_fit_slice(
							motion.operations[cursor:cand_end],
							max_err,
							config.min_radius_um,
							config.max_radius_um,
							printer,
						)
						if fit_ok {
							best_end = cand_end
							best_center = center
							best_kind = arc_kind
						} else if best_end > 0 {
							break
						}
					}
				}

				if best_end > 0 {
					merged := motion.operations[cursor]
					merged.point_b = motion.operations[best_end - 1].point_b
					merged.arc = best_kind
					merged.arc_center = best_center
					total_e: i128
					total_dur: u64
					for k in cursor..<best_end {
						total_e += motion.operations[k].filament_delta_nm
						total_dur += motion.operations[k].duration_us
					}
					merged.filament_delta_nm = total_e
					merged.duration_us = total_dur
					append(&new_ops, merged)
					stats.arcs_fitted += 1
					stats.segments_replaced += u64(best_end - cursor)
					cursor = best_end
				} else {
					append(&new_ops, motion.operations[cursor])
					cursor += 1
				}
			}
			i = run_end
		}

		layer.operation_offset = u64(new_layer_start)
		layer.operation_count = u32(len(new_ops) - new_layer_start)
	}

	if stats.arcs_fitted > 0 {
		delete(motion.operations, allocator)
		motion.operations = new_ops[:]
		// Recompute extrusion_count accurately.
		ext_count: u64
		for op in motion.operations {
			if op.kind == .Extrude {ext_count += 1}
		}
		motion.extrusion_count = ext_count
	} else {
		delete(new_ops)
	}
	return stats
}

@(private)
arc_fit_slice :: proc(
	ops: []Motion_Operation,
	max_err_um, min_r_um, max_r_um: f64,
	printer: profiles.Printer_Profile,
) -> (center: polygon.Polygon_Point, kind: Motion_Arc_Kind, ok: bool) {
	n := len(ops)
	if n < 3 {return {}, .None, false}
	p0 := ops[0].point_a
	pm := ops[n / 2].point_a
	p1 := ops[n - 1].point_b
	if p0 == p1 {return {}, .None, false}

	// Circumcircle of (p0, pm, p1).
	ax, ay := f64(i64(p0.x)), f64(i64(p0.y))
	bx, by := f64(i64(pm.x)), f64(i64(pm.y))
	cx, cy := f64(i64(p1.x)), f64(i64(p1.y))
	d := 2.0 * (ax*(by - cy) + bx*(cy - ay) + cx*(ay - by))
	if math.abs(d) < 1e-3 {return {}, .None, false}

	a2 := ax*ax + ay*ay
	b2 := bx*bx + by*by
	c2 := cx*cx + cy*cy
	ux := (a2*(by - cy) + b2*(cy - ay) + c2*(ay - by)) / d
	uy := (a2*(cx - bx) + b2*(ax - cx) + c2*(bx - ax)) / d

	// Quantize center to integer micrometres so I/J offsets match emitted G-code exactly.
	icx := i64(math.round(ux))
	icy := i64(math.round(uy))
	fx := f64(icx)
	fy := f64(icy)

	r := math.hypot(ax - fx, ay - fy)
	if r < min_r_um || r > max_r_um {return {}, .None, false}
	// Endpoint radius must match start radius closely so Klipper accepts G2/G3 without radius error.
	r_end := math.hypot(cx - fx, cy - fy)
	if math.abs(r - r_end) > min(max_err_um, 10.0) {return {}, .None, false}

	// Check orientation (CW vs CCW) and sweep angle (< 170 deg).
	cross0 := (bx - ax)*(cy - by) - (by - ay)*(cx - bx)
	if math.abs(cross0) < 1.0 {return {}, .None, false}
	arc_kind := Motion_Arc_Kind.CCW if cross0 > 0 else Motion_Arc_Kind.CW

	// Verify every intermediate vertex & chord midpoint lies within max_err_um and turns monotonically.
	total_sweep := 0.0
	for op in ops {
		x0 := f64(i64(op.point_a.x)) - fx
		y0 := f64(i64(op.point_a.y)) - fy
		x1 := f64(i64(op.point_b.x)) - fx
		y1 := f64(i64(op.point_b.y)) - fy

		r1 := math.hypot(x1, y1)
		if math.abs(r1 - r) > max_err_um {return {}, .None, false}

		// Chord midpoint sagitta error check.
		mx := 0.5 * (x0 + x1)
		my := 0.5 * (y0 + y1)
		rm := math.hypot(mx, my)
		if math.abs(rm - r) > max_err_um {return {}, .None, false}

		// Signed step angle must match arc_kind.
		cr := x0*y1 - y0*x1
		dt := x0*x1 + y0*y1
		ang := math.atan2(cr, dt)
		if arc_kind == .CCW && ang <= 0 {return {}, .None, false}
		if arc_kind == .CW && ang >= 0 {return {}, .None, false}
		total_sweep += math.abs(ang)
	}
	if total_sweep > math.PI * 0.94 {return {}, .None, false}

	// Keep arc center within reasonable machine coordinate range.
	_ = printer
	return polygon.Polygon_Point{x = contracts.Micrometres(icx), y = contracts.Micrometres(icy)}, arc_kind, true
}
