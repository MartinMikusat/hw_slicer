package features

import "core:math"

import contracts "../contracts"
import profiles "../profiles"

Scarf_Seam_Config :: struct {
	enabled:         bool,
	length_um:       contracts.Micrometres, // default 15_000 um (15 mm)
	start_height_pct: u32,                  // default 10% (ramps from -90% to 0%)
}

Scarf_Seam_Stats :: struct {
	loops_ramped: u64,
	ops_modified: u64,
}

// Applies OrcaSlicer-style scarf joint seams (smooth Z + E ramp at the start of outer perimeter loops)
// OR continuous helical Z interpolation for Spiral Vase Mode (`vase_mode = true`).
motion_plan_apply_z_ramps :: proc(
	motion: ^Motion_Plan_Result,
	layer_heights: []contracts.Micrometres,
	scarf: Scarf_Seam_Config,
	vase_mode: bool,
	vase_bottom_layers: u32,
	process: profiles.Process_Profile,
) -> Scarf_Seam_Stats {
	if motion == nil || (!scarf.enabled && !vase_mode) || len(motion.layers) == 0 {
		return {}
	}
	quantum := i128(max(u32(10), process.extrusion_length_quantum_nm))
	stats := Scarf_Seam_Stats{}

	for layer, li in motion.layers {
		if li == 0 {continue} // Keep layer 0 flat on the build plate.
		lh := i64(layer_heights[li]) if li < len(layer_heights) else i64(process.layer_height)
		if lh <= 0 {continue}

		op_start := int(layer.operation_offset)
		op_end := op_start + int(layer.operation_count)

		if vase_mode && u32(li) >= vase_bottom_layers {
			// Spiral Vase Mode: interpolate Z continuously from (layer.z - lh) -> layer.z across all perimeter moves.
			total_len := 0.0
			for oi in op_start..<op_end {
				op := motion.operations[oi]
				if op.kind == .Extrude && op.role == .Perimeter {
					total_len += math.hypot(f64(i64(op.point_b.x) - i64(op.point_a.x)), f64(i64(op.point_b.y) - i64(op.point_a.y)))
				}
			}
			if total_len > 1.0 {
				accum := 0.0
				for oi in op_start..<op_end {
					op := &motion.operations[oi]
					if op.kind != .Extrude || op.role != .Perimeter {continue}
					seg_len := math.hypot(f64(i64(op.point_b.x) - i64(op.point_a.x)), f64(i64(op.point_b.y) - i64(op.point_a.y)))
					accum += seg_len
					t := clamp(accum / total_len, 0.0, 1.0)
					z_off := i64(math.round(-f64(lh) * (1.0 - t)))
					op.z_offset_um = contracts.Micrometres(z_off)
					stats.ops_modified += 1
				}
				stats.loops_ramped += 1
			}
			continue
		}

		if !scarf.enabled {continue}
		ramp_len := f64(i64(scarf.length_um)) if i64(scarf.length_um) > 0 else 15_000.0
		start_frac := clamp(f64(scarf.start_height_pct) / 100.0, 0.05, 0.5) if scarf.start_height_pct > 0 else 0.1

		// Ramp the start of each contiguous Perimeter path within this layer.
		oi := op_start
		for oi < op_end {
			if motion.operations[oi].kind != .Extrude || motion.operations[oi].role != .Perimeter {
				oi += 1
				continue
			}
			pid := motion.operations[oi].path_id
			path_start := oi
			for oi < op_end && motion.operations[oi].kind == .Extrude && motion.operations[oi].path_id == pid {
				oi += 1
			}
			// Ramp along [path_start ..< oi] up to `ramp_len`.
			dist := 0.0
			ramped_any := false
			for k in path_start..<oi {
				op := &motion.operations[k]
				if op.arc != .None {break} // Keep G2/G3 arcs planar in XY.
				seg_len := math.hypot(f64(i64(op.point_b.x) - i64(op.point_a.x)), f64(i64(op.point_b.y) - i64(op.point_a.y)))
				if dist >= ramp_len {break}
				dist += seg_len
				t := clamp(dist / ramp_len, 0.0, 1.0)
				frac := start_frac + (1.0 - start_frac) * t
				z_off := i64(math.round(-f64(lh) * (1.0 - frac)))
				op.z_offset_um = contracts.Micrometres(z_off)
				// Scale filament proportionally to tapered cross-section, quantized to 10 nm.
				raw_e := i128(math.round(f64(op.filament_delta_nm) * frac))
				q_e := (raw_e / quantum) * quantum
				if q_e < quantum {q_e = quantum}
				op.filament_delta_nm = q_e
				stats.ops_modified += 1
				ramped_any = true
			}
			if ramped_any {stats.loops_ramped += 1}
		}
	}
	return stats
}
