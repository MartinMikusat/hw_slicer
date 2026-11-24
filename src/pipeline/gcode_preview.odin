package pipeline

import "base:runtime"
import "core:math"
import "core:mem"
import "core:sync"

import contracts "../contracts"
import features "../features"
import profiles "../profiles"

GCode_View_Mode :: enum u8 {
	Line_Type,
	Speed,
	Actual_Speed,
	Volumetric_Flow,
	Layer_Height,
	Line_Width,
	Fan_Speed,
	Temperature,
	Layer_Time,
	Layer_Time_Log,
	Pressure_Advance,
	Acceleration,
	Flow_Ratio,
	Filament,
}

GCode_View_Info :: struct {
	label:  string,
	unit:   string,
	is_log: bool,
}

GCODE_VIEW_INFOS := [GCode_View_Mode]GCode_View_Info{
	.Line_Type        = {label = "Line type",        unit = ""},
	.Speed            = {label = "Speed",            unit = "mm/s"},
	.Actual_Speed     = {label = "Actual speed",     unit = "mm/s"},
	.Volumetric_Flow  = {label = "Flow",             unit = "mm³/s"},
	.Layer_Height     = {label = "Layer height",     unit = "mm"},
	.Line_Width       = {label = "Line width",       unit = "mm"},
	.Fan_Speed        = {label = "Fan speed",        unit = "%"},
	.Temperature      = {label = "Temperature",      unit = "°C"},
	.Layer_Time       = {label = "Layer time",       unit = "s"},
	.Layer_Time_Log   = {label = "Layer time (log)", unit = "s", is_log = true},
	.Pressure_Advance = {label = "Pressure advance", unit = "mm/s"},
	.Acceleration     = {label = "Acceleration",     unit = "mm/s²"},
	.Flow_Ratio       = {label = "Flow ratio",       unit = "%"},
	.Filament         = {label = "Filament",         unit = ""},
}

GCode_Line_Swatch :: struct {
	label: string,
	color: [4]f32,
}

GCODE_LINE_SWATCHES := [?]GCode_Line_Swatch{
	{label = "Outer wall",        color = {0.95, 0.45, 0.15, 1.0}},
	{label = "Inner wall",        color = {0.96, 0.78, 0.22, 1.0}},
	{label = "Top surface",       color = {0.88, 0.24, 0.26, 1.0}},
	{label = "Bottom / solid",    color = {0.68, 0.28, 0.78, 1.0}},
	{label = "Sparse infill",     color = {0.58, 0.14, 0.20, 1.0}},
	{label = "Bridge",            color = {0.18, 0.56, 0.96, 1.0}},
	{label = "Gap fill",          color = {0.92, 0.92, 0.94, 1.0}},
	{label = "Support",           color = {0.18, 0.78, 0.36, 1.0}},
	{label = "Support interface", color = {0.12, 0.52, 0.42, 1.0}},
}

GCode_Preview_Bead :: struct {
	a:               [3]f32,
	b:               [3]f32,
	width_mm:        f32,
	height_mm:       f32,
	layer_index:     u32,
	role:            profiles.Printable_Role,
	is_outer_wall:   bool,
	cmd_speed_mm_s:  f32,
	actual_speed:    f32,
	flow_mm3_s:      f32,
	fan_pct:         f32,
	temp_c:          f32,
	layer_time_s:    f32,
	pa_load_mm_s:    f32,
	accel_mm_s2:     f32,
	flow_ratio_pct:  f32,
}

GCode_Preview_Data :: struct {
	built_hash:         contracts.Content_Hash,
	beads:              []GCode_Preview_Bead,
	layer_bead_offsets: []int,
	layer_bead_counts:  []int,
	mode_min:           [GCode_View_Mode]f32,
	mode_max:           [GCode_View_Mode]f32,
}

gcode_preview_destroy :: proc(p: ^GCode_Preview_Data, allocator := context.allocator) {
	if p == nil {return}
	delete(p.beads, allocator)
	delete(p.layer_bead_offsets, allocator)
	delete(p.layer_bead_counts, allocator)
	p^ = {}
}

// Evaluates the 3-pass Klipper SCV trapezoid kinematics solver over `w.session.motion` and
// builds the full 3D bead list with every OrcaSlicer G-code preview metric precomputed.
workspace_build_gcode_preview :: proc(
	w: ^Workspace,
	allocator := context.allocator,
) -> (GCode_Preview_Data, bool) {
	if w == nil || w.session == nil {return {}, false}
	s := w.session
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	if !session_readable(s, {.Model, .Layer_Schedule, .Motion}) {return {}, false}
	if len(s.motion.operations) == 0 || len(s.motion.layers) == 0 {return {}, false}

	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	motion := s.motion
	ext := s.extrusion
	plan := s.unified_plan
	perim := s.perimeters
	prof := s.profile
	b := s.mesh.bounds
	origin_x := f64(b.minimum.x + b.maximum.x) * 0.5
	origin_y := f64(b.minimum.y + b.maximum.y) * 0.5

	// Identify outer perimeter path IDs so Line_Type distinguishes Outer vs Inner wall.
	outer_paths := make(map[contracts.Stable_ID]struct{}, 256, context.temp_allocator)
	for path in plan.paths {
		if path.source_kind == .Perimeter &&
		   int(path.source_index) < len(perim.paths) &&
		   perim.paths[path.source_index].perimeter_index == 0 {
			outer_paths[path.stable_id] = {}
		}
	}

	// Build fast lookup from planned move index -> extrusion move index.
	plan_to_ext := make([]int, len(plan.moves), context.temp_allocator)
	for i in 0..<len(plan_to_ext) {plan_to_ext[i] = -1}
	for em, ei in ext.moves {
		if int(em.planned_move_index) < len(plan_to_ext) {
			plan_to_ext[em.planned_move_index] = ei
		}
	}

	// 3-pass Klipper SCV trapezoid kinematics solver (matches motion_plan_estimate_klipper_time).
	scv := 5.0
	Kin_Move :: struct {
		op_index:    int,
		dist:        f64,
		v_cruise:    f64,
		accel:       f64,
		v_entry:     f64,
		stop_before: bool,
	}
	kin_moves := make([dynamic]Kin_Move, 0, len(motion.operations), context.temp_allocator)
	op_to_kin := make([]int, len(motion.operations), context.temp_allocator)
	for i in 0..<len(op_to_kin) {op_to_kin[i] = -1}

	layer_count := len(s.schedule.print_z)
	layer_times := make([]f64, layer_count, context.temp_allocator)

	stop_pending := true
	prev_ux, prev_uy: f64
	for op, oi in motion.operations {
		li := int(op.layer_index)
		switch op.kind {
		case .Dwell, .Retract, .Recover:
			if li >= 0 && li < layer_count {
				layer_times[li] += f64(op.duration_us) / 1_000_000.0
			}
			stop_pending = true
		case .Travel, .Extrude:
			dx := f64(i64(op.point_b.x) - i64(op.point_a.x)) / 1000.0
			dy := f64(i64(op.point_b.y) - i64(op.point_a.y)) / 1000.0
			dist := math.hypot(dx, dy)
			ux, uy, exit_ux, exit_uy: f64
			r := 0.0
			if op.kind == .Extrude && op.arc != .None {
				rx0 := f64(i64(op.point_a.x) - i64(op.arc_center.x)) / 1000.0
				ry0 := f64(i64(op.point_a.y) - i64(op.arc_center.y)) / 1000.0
				rx1 := f64(i64(op.point_b.x) - i64(op.arc_center.x)) / 1000.0
				ry1 := f64(i64(op.point_b.y) - i64(op.arc_center.y)) / 1000.0
				r = math.hypot(rx0, ry0)
				if r > 1e-6 {
					a0 := math.atan2(ry0, rx0)
					a1 := math.atan2(ry1, rx1)
					sweep := a1 - a0
					r1 := max(1e-6, math.hypot(rx1, ry1))
					if op.arc == .CCW {
						if sweep <= 0 {sweep += 2.0 * math.PI}
						ux, uy = -ry0 / r, rx0 / r
						exit_ux, exit_uy = -ry1 / r1, rx1 / r1
					} else {
						if sweep >= 0 {sweep -= 2.0 * math.PI}
						sweep = -sweep
						ux, uy = ry0 / r, -rx0 / r
						exit_ux, exit_uy = ry1 / r1, -rx1 / r1
					}
					dist = r * sweep
				}
			}
			if r <= 1e-6 {
				if dist < 1e-6 {continue}
				ux, uy = dx / dist, dy / dist
				exit_ux, exit_uy = ux, uy
			}
			v_cruise := max(0.1, f64(i64(op.speed)) / 1000.0)
			accel := max(10.0, f64(i64(op.acceleration)) / 1000.0)
			v_junction := 0.0
			if !stop_pending && len(kin_moves) > 0 {
				prev := kin_moves[len(kin_moves)-1]
				cos_t := clamp(prev_ux*ux + prev_uy*uy, -1.0, 1.0)
				v_junction = min(prev.v_cruise, v_cruise)
				if 0.5 * (1.0 - cos_t) >= 1e-8 {
					v_junction = min(v_junction, scv * math.sqrt(max(0.0, (1.0 + cos_t) / max(1e-6, 1.0 - cos_t))))
				}
			}
			hop := op.kind == .Travel && i64(op.z_hop_um) > 0
			if hop {v_junction = 0}
			op_to_kin[oi] = len(kin_moves)
			append(&kin_moves, Kin_Move{
				op_index    = oi,
				dist        = dist,
				v_cruise    = v_cruise,
				accel       = accel,
				v_entry     = v_junction,
				stop_before = stop_pending || hop,
			})
			stop_pending = hop
			prev_ux, prev_uy = exit_ux, exit_uy
		case .Invalid:
		}
	}

	next_entry := 0.0
	for i := len(kin_moves) - 1; i >= 0; i -= 1 {
		m := &kin_moves[i]
		m.v_entry = min(m.v_entry, math.sqrt(next_entry*next_entry + 2.0*m.accel*m.dist))
		next_entry = 0.0 if m.stop_before else m.v_entry
	}
	for i in 0..<len(kin_moves) - 1 {
		if kin_moves[i+1].stop_before {continue}
		m := kin_moves[i]
		kin_moves[i+1].v_entry = min(kin_moves[i+1].v_entry, math.sqrt(m.v_entry*m.v_entry + 2.0*m.accel*m.dist))
	}

	kin_actual_speed := make([]f32, len(kin_moves), context.temp_allocator)
	kin_duration_s := make([]f64, len(kin_moves), context.temp_allocator)
	kin_pa_load := make([]f32, len(kin_moves), context.temp_allocator)
	// Klipper default pressure advance constant (s) for dynamic PA demand visualization.
	pa_s := 0.04
	for m, i in kin_moves {
		v_exit := 0.0
		if i + 1 < len(kin_moves) && !kin_moves[i+1].stop_before {v_exit = kin_moves[i+1].v_entry}
		dt, v_peak := preview_trap_time_and_peak(m.dist, m.v_entry, m.v_cruise, v_exit, m.accel)
		kin_duration_s[i] = dt
		kin_actual_speed[i] = f32(m.dist / dt) if dt > 1e-7 else f32(m.v_cruise)
		// Dynamic pressure-advance surge velocity: PA * max(|v_peak - v_entry|, |v_peak - v_exit|) / (dt * 0.5) ~ PA * accel when ramping.
		dv := max(abs(v_peak - m.v_entry), abs(v_peak - v_exit))
		kin_pa_load[i] = f32(pa_s * dv / max(0.002, dt))
		li := int(motion.operations[m.op_index].layer_index)
		if li >= 0 && li < layer_count {
			layer_times[li] += dt
		}
	}

	// Filament cross-section area (mm^2) for volumetric flow computation from filament_delta_nm.
	fil_d_mm := f64(i64(prof.material.filament_diameter)) / 1000.0
	if fil_d_mm <= 0 {fil_d_mm = 1.75}
	fil_area_mm2 := math.PI * 0.25 * fil_d_mm * fil_d_mm
	nozzle_temp_c := f32(i32(prof.process.source.nozzle_temperature))
	nom_width_mm := f32(f64(i64(prof.process.source.nominal_line_width)) / 1000.0)

	out_beads := make([dynamic]GCode_Preview_Bead, 0, len(motion.operations), allocator)
	offsets := make([]int, layer_count, allocator)
	counts := make([]int, layer_count, allocator)

	for l in motion.layers {
		li := int(l.layer_index)
		if li < 0 || li >= layer_count {continue}
		offsets[li] = len(out_beads)
		lh_mm := f32(f64(i64(s.layer_heights[li])) / 1000.0) if li < len(s.layer_heights) else f32(f64(i64(prof.process.source.layer_height)) / 1000.0)
		base_z_mm := f64(i64(l.z)) / 1000.0
		lt_s := f32(layer_times[li])
		// First layer typically prints +5 C hotter or at nominal nozzle temperature.
		temp_c := nozzle_temp_c

		first := int(l.operation_offset)
		last := min(first + int(l.operation_count), len(motion.operations))
		for oi in first..<last {
			op := motion.operations[oi]
			if op.kind != .Extrude {continue}
			ki := op_to_kin[oi]
			cmd_spd := f32(f64(i64(op.speed)) / 1000.0)
			act_spd := kin_actual_speed[ki] if ki >= 0 else cmd_spd
			dt_s := kin_duration_s[ki] if ki >= 0 else (f64(op.duration_us) / 1_000_000.0)
			pa_val := kin_pa_load[ki] if ki >= 0 else 0
			accel_val := f32(f64(i64(op.acceleration)) / 1000.0)
			fan_pct := f32(f64(op.fan_ratio) / 10_000.0)

			// Volumetric flow (mm^3/s) = extruded filament volume (mm^3) / actual duration (s).
			fil_len_mm := f64(op.filament_delta_nm) / 1_000_000.0
			vol_mm3 := fil_len_mm * fil_area_mm2
			flow_mm3_s := f32(vol_mm3 / dt_s) if dt_s > 1e-7 else 0

			width_mm := nom_width_mm
			flow_ratio_pct := f32(100.0)
			if int(op.source_move_index) < len(plan_to_ext) {
				ei := plan_to_ext[op.source_move_index]
				if ei >= 0 && ei < len(ext.moves) {
					em := ext.moves[ei]
					width_mm = f32(f64(i64(em.line_width_a) + i64(em.line_width_b)) / 2000.0)
					flow_ratio_pct = f32(f64(em.flow_ratio) / 10_000.0)
				}
			}

			_, is_outer := outer_paths[op.path_id]
			z_mm := f32(max(0.0, base_z_mm + f64(i64(op.z_offset_um))/1000.0))

			proto := GCode_Preview_Bead{
				width_mm       = max(0.05, width_mm),
				height_mm      = max(0.04, lh_mm),
				layer_index    = op.layer_index,
				role           = op.role,
				is_outer_wall  = is_outer,
				cmd_speed_mm_s = cmd_spd,
				actual_speed   = act_spd,
				flow_mm3_s     = flow_mm3_s,
				fan_pct        = fan_pct,
				temp_c         = temp_c,
				layer_time_s   = lt_s,
				pa_load_mm_s   = pa_val,
				accel_mm_s2    = accel_val,
				flow_ratio_pct = flow_ratio_pct,
			}

			if op.arc != .None {
				// Tessellate G2/G3 arc into smooth 3D bead chords (~0.5 mm or <= 15 deg).
				cx := f64(i64(op.arc_center.x)) / 1000.0
				cy := f64(i64(op.arc_center.y)) / 1000.0
				ax := f64(i64(op.point_a.x)) / 1000.0
				ay := f64(i64(op.point_a.y)) / 1000.0
				bx := f64(i64(op.point_b.x)) / 1000.0
				by := f64(i64(op.point_b.y)) / 1000.0
				r := math.hypot(ax - cx, ay - cy)
				if r > 1e-4 {
					a0 := math.atan2(ay - cy, ax - cx)
					a1 := math.atan2(by - cy, bx - cx)
					sweep := a1 - a0
					if op.arc == .CCW {
						if sweep <= 0 {sweep += 2.0 * math.PI}
					} else {
						if sweep >= 0 {sweep -= 2.0 * math.PI}
					}
					steps := clamp(int(math.ceil(abs(sweep) / (math.PI / 16.0))), 2, 32)
					px, py := ax, ay
					for si in 1..=steps {
						t := f64(si) / f64(steps)
						ang := a0 + sweep * t
						nx := bx if si == steps else (cx + r * math.cos(ang))
						ny := by if si == steps else (cy + r * math.sin(ang))
						seg := proto
						seg.a = {f32(px - origin_x), f32(py - origin_y), z_mm}
						seg.b = {f32(nx - origin_x), f32(ny - origin_y), z_mm}
						append(&out_beads, seg)
						px, py = nx, ny
					}
					continue
				}
			}

			seg := proto
			seg.a = {f32(f64(i64(op.point_a.x))/1000.0 - origin_x), f32(f64(i64(op.point_a.y))/1000.0 - origin_y), z_mm}
			seg.b = {f32(f64(i64(op.point_b.x))/1000.0 - origin_x), f32(f64(i64(op.point_b.y))/1000.0 - origin_y), z_mm}
			append(&out_beads, seg)
		}
		counts[li] = len(out_beads) - offsets[li]
	}

	res := GCode_Preview_Data{
		built_hash         = s.slots[.Motion].built_hash,
		beads              = out_beads[:],
		layer_bead_offsets = offsets,
		layer_bead_counts  = counts,
	}
	for mode in GCode_View_Mode {
		res.mode_min[mode] = max(f32)
		res.mode_max[mode] = -max(f32)
	}
	for bd in res.beads {
		for mode in GCode_View_Mode {
			if mode == .Line_Type || mode == .Filament {continue}
			v := gcode_preview_bead_metric(bd, mode)
			if v < res.mode_min[mode] {res.mode_min[mode] = v}
			if v > res.mode_max[mode] {res.mode_max[mode] = v}
		}
	}
	for mode in GCode_View_Mode {
		if res.mode_min[mode] > res.mode_max[mode] {
			res.mode_min[mode] = 0
			res.mode_max[mode] = 1
		}
	}
	return res, true
}

gcode_preview_bead_metric :: proc(bd: GCode_Preview_Bead, mode: GCode_View_Mode) -> f32 {
	switch mode {
	case .Line_Type, .Filament: return 0
	case .Speed:                return bd.cmd_speed_mm_s
	case .Actual_Speed:         return bd.actual_speed
	case .Volumetric_Flow:      return bd.flow_mm3_s
	case .Layer_Height:         return bd.height_mm
	case .Line_Width:           return bd.width_mm
	case .Fan_Speed:            return bd.fan_pct
	case .Temperature:          return bd.temp_c
	case .Layer_Time:           return bd.layer_time_s
	case .Layer_Time_Log:       return bd.layer_time_s
	case .Pressure_Advance:     return bd.pa_load_mm_s
	case .Acceleration:         return bd.accel_mm_s2
	case .Flow_Ratio:           return bd.flow_ratio_pct
	}
	return 0
}

// OrcaSlicer-inspired color for a bead under `mode`.
gcode_preview_bead_color :: proc(
	bd: GCode_Preview_Bead,
	mode: GCode_View_Mode,
	min_v, max_v: f32,
) -> [4]f32 {
	switch mode {
	case .Line_Type:
		switch bd.role {
		case .Perimeter:
			return {0.95, 0.45, 0.15, 1.0} if bd.is_outer_wall else {0.96, 0.78, 0.22, 1.0}
		case .Top_Skin:          return {0.88, 0.24, 0.26, 1.0}
		case .Bottom_Skin:       return {0.68, 0.28, 0.78, 1.0}
		case .Top_Bottom_Skin:   return {0.82, 0.28, 0.56, 1.0}
		case .Sparse_Infill:     return {0.58, 0.14, 0.20, 1.0}
		case .Bridge:            return {0.18, 0.56, 0.96, 1.0}
		case .Gap, .Thin_Wall:   return {0.92, 0.92, 0.94, 1.0}
		case .Support:           return {0.18, 0.78, 0.36, 1.0}
		case .Support_Interface: return {0.12, 0.52, 0.42, 1.0}
		case .Invalid:           return {0.70, 0.70, 0.72, 1.0}
		}
	case .Filament:
		return {0.92, 0.90, 0.86, 1.0}
	case .Speed, .Actual_Speed, .Volumetric_Flow, .Layer_Height, .Line_Width,
	     .Fan_Speed, .Temperature, .Layer_Time, .Layer_Time_Log,
	     .Pressure_Advance, .Acceleration, .Flow_Ratio:
		v := gcode_preview_bead_metric(bd, mode)
		t: f32
		if mode == .Layer_Time_Log {
			lo := math.log10(max(f32(0.05), min_v))
			hi := math.log10(max(f32(0.06), max_v))
			cur := math.log10(max(f32(0.05), v))
			t = clamp((cur - lo) / (hi - lo), 0, 1) if hi > lo + 1e-5 else 0.5
		} else {
			span := max_v - min_v
			t = clamp((v - min_v) / span, 0, 1) if span > 1e-5 else 0.5
		}
		return gcode_preview_heat_color(t)
	}
	return {0.8, 0.8, 0.8, 1.0}
}

// Smooth 5-stop blue -> cyan -> green -> yellow -> red gradient matching OrcaSlicer's legends.
gcode_preview_heat_color :: proc(t_in: f32) -> [4]f32 {
	t := clamp(t_in, 0, 1)
	stops := [5][3]f32{
		{0.10, 0.32, 0.88}, // 0.00 blue
		{0.10, 0.76, 0.84}, // 0.25 cyan
		{0.20, 0.82, 0.32}, // 0.50 green
		{0.96, 0.84, 0.16}, // 0.75 yellow
		{0.92, 0.20, 0.16}, // 1.00 red
	}
	scaled := t * 4.0
	idx := min(int(scaled), 3)
	f := scaled - f32(idx)
	a := stops[idx]
	b := stops[idx+1]
	return {
		a[0] + (b[0] - a[0]) * f,
		a[1] + (b[1] - a[1]) * f,
		a[2] + (b[2] - a[2]) * f,
		1.0,
	}
}

@(private = "file")
preview_trap_time_and_peak :: proc(dist, v0, v_max, v1, accel: f64) -> (dt: f64, v_peak: f64) {
	if dist <= 0 || v_max <= 0 || accel <= 0 {return 0, v0}
	d_acc := max(0.0, (v_max*v_max - v0*v0) / (2.0 * accel))
	d_dec := max(0.0, (v_max*v_max - v1*v1) / (2.0 * accel))
	if d_acc + d_dec <= dist {
		t_acc := max(0.0, (v_max - v0) / accel)
		t_dec := max(0.0, (v_max - v1) / accel)
		t_cruise := (dist - d_acc - d_dec) / v_max
		return t_acc + t_cruise + t_dec, v_max
	}
	vp := math.sqrt(max(0.0, 0.5*(v0*v0 + v1*v1) + accel*dist))
	return max(0.0, (vp - v0)/accel) + max(0.0, (vp - v1)/accel), vp
}
