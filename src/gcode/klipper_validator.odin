package gcode

import "base:intrinsics"
import "core:simd"
import "core:strings"

import contracts "../contracts"
import features "../features"
import profiles "../profiles"

Klipper_Validation_Error :: enum u8 {
	None,
	Invalid_Encoding,
	Invalid_Syntax,
	Unsupported_Command,
	Invalid_Sequence,
	Machine_Bounds,
	Motion_Mismatch,
	Final_State,
	Arithmetic,
}

Klipper_Validation_Report :: struct {
	command_count:         u64,
	layer_count:           u32,
	motion_operation_count: u64,
	positive_filament_nm:  u128,
	negative_filament_nm:  u128,
	dwell_ms:              u64,
	final_x:               contracts.Micrometres,
	final_y:               contracts.Micrometres,
	final_z:               contracts.Micrometres,
	final_fan_pwm:         i32,
	nozzle_temperature:    i32,
	bed_temperature:       i32,
	print_ended:           bool,
}

Klipper_Parsed_Kind :: enum u8 {
	Invalid,
	Header,
	Layer,
	G21,
	G90,
	G0,
	G1,
	G2,
	G3,
	G4,
	M83,
	M106,
	M107,
	Start_Print,
	End_Print,
	Set_Velocity_Limit,
	Print_Stats_Total,
	Print_Stats_Current,
	Exclude_Object,
	Pause_Or_Filament,
}

Klipper_Parsed_Command :: struct {
	kind:        Klipper_Parsed_Kind,
	layer_index: u32,
	layer_z:     i64,
	has_x:       bool,
	has_y:       bool,
	has_z:       bool,
	has_i:       bool,
	has_j:       bool,
	has_e:       bool,
	has_f:       bool,
	has_s:       bool,
	has_p:       bool,
	has_r:       bool,
	has_t:       bool,
	x:           i64,
	y:           i64,
	z:           i64,
	i:           i64,
	j:           i64,
	e_nm:        i128,
	f:           i64,
	s:           i64,
	p:           i64,
	r:           i64,
	t:           i64,
	value:       i64, // ACCEL, TOTAL_LAYER or CURRENT_LAYER
	extruder_temperature:       i64,
	extruder_other_temperature: i64,
	bed_temperature:            i64,
	area:        [4]i64, // X0, Y0, X1, Y1 in µm
}

Klipper_Startup_Stage :: enum u8 {
	Header,
	Total_Layers,
	Start_Print,
	Millimetres,
	Absolute_Coordinates,
	Relative_Extrusion,
	Fan_Off,
	Complete,
}

Klipper_Validation_State :: struct {
	startup:              Klipper_Startup_Stage,
	current_layer:        u32,
	layer_active:         bool,
	layer_announced:      bool,
	layer_z_emitted:      bool,
	operation_index:      u64,
	positioned_xy:        bool,
	x:                    i64,
	y:                    i64,
	z:                    i64,
	physical_z:           i64,
	acceleration:         i64,
	fan_pwm:              i32,
	z_hop_stage:          u8, // 0 = none, 1 = hopped up awaiting XY, 2 = XY done awaiting un-hop
}

// 16-byte ARM64 NEON scanner: validates printable ASCII [0x20..0x7e] 16 bytes at a time and
// returns the index of the terminating '\n' (or ok=false on empty line, invalid byte, or EOF).
@(private = "file")
klipper_scan_line_end :: #force_inline proc(bytes: []u8, start: int) -> (end: int, ok: bool) {
	n := len(bytes)
	i := start
	v_lo := #simd[16]u8{0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20}
	v_hi := #simd[16]u8{0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e, 0x7e}
	for i + 16 <= n {
		v := intrinsics.unaligned_load((^#simd[16]u8)(&bytes[i]))
		bad := simd.lanes_lt(v, v_lo) | simd.lanes_gt(v, v_hi)
		if simd.reduce_or(bad) == 0 {
			i += 16
			continue
		}
		break
	}
	for ; i < n; i += 1 {
		b := bytes[i]
		if b == '\n' {
			return i, i > start
		}
		if b < 0x20 || b > 0x7e {
			return i, false
		}
	}
	return n, false
}

klipper_validate :: proc(
	bytes: []u8,
	profile: profiles.Resolved_Profiles,
	motion: features.Motion_Plan_Result,
	require_stable_ids := true,
) -> (Klipper_Validation_Report, Klipper_Validation_Error) {
	if len(bytes) == 0 || bytes[len(bytes)-1] != '\n' ||
	   !klipper_motion_valid(motion, profile, require_stable_ids) {
		return {}, .Invalid_Encoding
	}
	state := Klipper_Validation_State{
		startup = .Header,
		current_layer = max(u32),
		acceleration = -1,
		fan_pwm = -1,
	}
	report := Klipper_Validation_Report{}
	line_start := 0
	for line_start < len(bytes) {
		byte_index, line_ok := klipper_scan_line_end(bytes, line_start)
		if !line_ok {
			return {}, .Invalid_Encoding
		}
		line := string(bytes[line_start:byte_index])
		command, parse_error := klipper_parse_command(line)
		if parse_error != .None {return {}, parse_error}
		report.command_count += 1
		if state.startup != .Complete {
			startup_error := klipper_validate_startup(
				command,
				profile,
				motion,
				&state,
				&report,
			)
			if startup_error != .None {
				return {}, startup_error
			}
		} else if klipper_printing_complete(state, motion) {
			shutdown_error := klipper_validate_shutdown(command, &report)
			if shutdown_error != .None {
				return {}, shutdown_error
			}
		} else {
			print_error := klipper_validate_print_command(
				command,
				profile,
				motion,
				&state,
				&report,
			)
			if print_error != .None {return {}, print_error}
		}
		line_start = byte_index+1
	}
	if line_start != len(bytes) ||
	   state.startup != .Complete ||
	   !klipper_printing_complete(state, motion) ||
	   !report.print_ended {
		return {}, .Final_State
	}
	expected_positive, expected_negative, expected_dwell, evidence_ok :=
		klipper_expected_evidence(motion, profile)
	if !evidence_ok ||
	   report.layer_count != u32(len(motion.layers)) ||
	   report.motion_operation_count != u64(len(motion.operations)) ||
	   report.positive_filament_nm != expected_positive ||
	   report.negative_filament_nm != expected_negative ||
	   report.dwell_ms != expected_dwell {
		return {}, .Final_State
	}
	report.final_x = contracts.Micrometres(state.x)
	report.final_y = contracts.Micrometres(state.y)
	report.final_z = contracts.Micrometres(state.z)
	return report, .None
}

// Validates one layer's emitted G-code slice in isolation, starting from the precomputed entry
// state. Callers verify state continuity across layer boundaries after parallel execution.
@(private)
klipper_validate_layer_slice :: proc(
	bytes: []u8,
	layer_index: u32,
	init: Klipper_State,
	profile: profiles.Resolved_Profiles,
	motion: features.Motion_Plan_Result,
) -> (
	state: Klipper_Validation_State,
	report: Klipper_Validation_Report,
	err: Klipper_Validation_Error,
) {
	state = Klipper_Validation_State{
		startup         = .Complete,
		current_layer   = layer_index-1 if layer_index > 0 else max(u32),
		layer_active    = false,
		operation_index = motion.layers[layer_index].operation_offset,
		positioned_xy   = init.positioned_xy,
		x               = i64(init.x),
		y               = i64(init.y),
		z               = i64(init.z),
		physical_z      = i64(init.physical_z),
		acceleration    = init.acceleration,
		fan_pwm         = init.fan_pwm,
	}
	report = Klipper_Validation_Report{
		layer_count   = layer_index,
		final_fan_pwm = init.fan_pwm,
	}
	line_start := 0
	for line_start < len(bytes) {
		byte_index, line_ok := klipper_scan_line_end(bytes, line_start)
		if !line_ok {
			return {}, {}, .Invalid_Encoding
		}
		line := string(bytes[line_start:byte_index])
		command, parse_error := klipper_parse_command(line)
		if parse_error != .None {return {}, {}, parse_error}
		report.command_count += 1
		print_error := klipper_validate_print_command(command, profile, motion, &state, &report)
		if print_error != .None {return {}, {}, print_error}
		line_start = byte_index+1
	}
	if line_start != len(bytes) ||
	   state.current_layer != layer_index ||
	   !klipper_current_layer_complete(state, motion) ||
	   state.z_hop_stage != 0 {
		return {}, {}, .Final_State
	}
	return state, report, .None
}

// Validates the startup header lines before layer 0 (and optional EXCLUDE_OBJECT_* lines).
@(private)
klipper_validate_header_slice :: proc(
	bytes: []u8,
	profile: profiles.Resolved_Profiles,
	motion: features.Motion_Plan_Result,
) -> (
	state: Klipper_Validation_State,
	report: Klipper_Validation_Report,
	err: Klipper_Validation_Error,
) {
	state = Klipper_Validation_State{
		startup       = .Header,
		current_layer = max(u32),
		acceleration  = -1,
		fan_pwm       = -1,
	}
	line_start := 0
	for b, byte_index in bytes {
		if b == '\r' || b == 0 || (b < 0x20 && b != '\n') || b > 0x7e {
			return {}, {}, .Invalid_Encoding
		}
		if b != '\n' {continue}
		if byte_index == line_start {
			return {}, {}, .Invalid_Encoding
		}
		line := string(bytes[line_start:byte_index])
		command, parse_error := klipper_parse_command(line)
		if parse_error != .None {return {}, {}, parse_error}
		report.command_count += 1
		if state.startup != .Complete {
			startup_error := klipper_validate_startup(command, profile, motion, &state, &report)
			if startup_error != .None {return {}, {}, startup_error}
		} else {
			print_error := klipper_validate_print_command(command, profile, motion, &state, &report)
			if print_error != .None {return {}, {}, print_error}
		}
		line_start = byte_index+1
	}
	if line_start != len(bytes) || state.startup != .Complete {
		return {}, {}, .Final_State
	}
	return state, report, .None
}

// Validates the shutdown footer lines after the last layer.
@(private)
klipper_validate_footer_slice :: proc(
	bytes: []u8,
	report: ^Klipper_Validation_Report,
) -> Klipper_Validation_Error {
	line_start := 0
	for b, byte_index in bytes {
		if b == '\r' || b == 0 || (b < 0x20 && b != '\n') || b > 0x7e {
			return .Invalid_Encoding
		}
		if b != '\n' {continue}
		if byte_index == line_start {
			return .Invalid_Encoding
		}
		line := string(bytes[line_start:byte_index])
		command, parse_error := klipper_parse_command(line)
		if parse_error != .None {return parse_error}
		report.command_count += 1
		shutdown_error := klipper_validate_shutdown(command, report)
		if shutdown_error != .None {return shutdown_error}
		line_start = byte_index+1
	}
	if line_start != len(bytes) || !report.print_ended {
		return .Final_State
	}
	return .None
}

klipper_validate_startup :: proc(
	command: Klipper_Parsed_Command,
	profile: profiles.Resolved_Profiles,
	motion: features.Motion_Plan_Result,
	state: ^Klipper_Validation_State,
	report: ^Klipper_Validation_Report,
) -> Klipper_Validation_Error {
	switch state.startup {
	case .Header:
		if command.kind != .Header {return .Invalid_Sequence}
	case .Total_Layers:
		if command.kind != .Print_Stats_Total ||
		   command.value != i64(len(motion.layers)) {
			return .Invalid_Sequence
		}
	case .Start_Print:
		process := profile.process.source
		area := klipper_extrusion_area(motion)
		expected_area := [4]i64{i64(area[0].x), i64(area[0].y), i64(area[1].x), i64(area[1].y)}
		if command.kind != .Start_Print ||
		   command.extruder_temperature != i64(process.nozzle_temperature) ||
		   command.extruder_other_temperature != i64(process.nozzle_temperature) ||
		   command.bed_temperature != i64(process.bed_temperature) ||
		   command.area != expected_area {
			return .Invalid_Sequence
		}
		report.nozzle_temperature = i32(command.extruder_temperature)
		report.bed_temperature = i32(command.bed_temperature)
	case .Millimetres:
		if command.kind != .G21 {return .Invalid_Sequence}
	case .Absolute_Coordinates:
		if command.kind != .G90 {return .Invalid_Sequence}
	case .Relative_Extrusion:
		if command.kind != .M83 {return .Invalid_Sequence}
	case .Fan_Off:
		if command.kind != .M107 {return .Invalid_Sequence}
		state.fan_pwm = 0
		report.final_fan_pwm = 0
	case .Complete:
		return .Invalid_Sequence
	}
	state.startup = Klipper_Startup_Stage(u8(state.startup)+1)
	return .None
}

klipper_validate_print_command :: proc(
	command: Klipper_Parsed_Command,
	profile: profiles.Resolved_Profiles,
	motion: features.Motion_Plan_Result,
	state: ^Klipper_Validation_State,
	report: ^Klipper_Validation_Report,
) -> Klipper_Validation_Error {
	switch command.kind {
	case .Layer:
		if state.layer_active &&
		   !klipper_current_layer_complete(state^, motion) {
			return .Invalid_Sequence
		}
		next_layer := report.layer_count
		if command.layer_index != next_layer ||
		   u64(next_layer) >= u64(len(motion.layers)) ||
		   command.layer_z != i64(motion.layers[next_layer].z) {
			return .Motion_Mismatch
		}
		state.current_layer = next_layer
		state.layer_active = true
		state.layer_announced = false
		state.layer_z_emitted = false
		report.layer_count += 1
		return .None
	case .Print_Stats_Current:
		if !state.layer_active || state.layer_announced ||
		   command.value != i64(state.current_layer)+1 {
			return .Invalid_Sequence
		}
		state.layer_announced = true
		return .None
	case .Set_Velocity_Limit:
		return klipper_apply_acceleration(command, profile, state)
	case .M106, .M107:
		return klipper_apply_fan(command, state, report)
	case .Exclude_Object, .Pause_Or_Filament:
		return .None
	case .G0, .G1, .G2, .G3:
		return klipper_validate_print_move(
			command,
			profile,
			motion,
			state,
			report,
		)
	case .G4:
		return klipper_validate_print_dwell(
			command,
			motion,
			state,
			report,
		)
	case .Invalid, .Header, .G21, .G90, .M83, .Start_Print, .End_Print,
	     .Print_Stats_Total:
		return .Invalid_Sequence
	}
	return .Invalid_Sequence
}

klipper_validate_print_move :: proc(
	command: Klipper_Parsed_Command,
	profile: profiles.Resolved_Profiles,
	motion: features.Motion_Plan_Result,
	state: ^Klipper_Validation_State,
	report: ^Klipper_Validation_Report,
) -> Klipper_Validation_Error {
	if !state.layer_active {return .Invalid_Sequence}
	layer := motion.layers[state.current_layer]
	travel_feed :=
		klipper_feed_rate(profile.process.source.travel.speed)
	travel_acceleration :=
		i64(profile.process.source.travel.acceleration)/1_000
	if !state.layer_z_emitted {
		if !state.layer_announced ||
		   command.kind != .G0 ||
		   command.has_x || command.has_y || command.has_e ||
		   !command.has_z || !command.has_f ||
		   command.z != i64(klipper_layer_start_z(motion, layer)) ||
		   command.f != travel_feed ||
		   state.acceleration != travel_acceleration {
			return .Motion_Mismatch
		}
		state.z = i64(layer.z)
		state.physical_z = command.z
		state.layer_z_emitted = true
		return .None
	}
	operation, operation_ok :=
		klipper_current_operation(state^, motion)
	if !operation_ok {return .Invalid_Sequence}
	if !state.positioned_xy && operation.kind != .Dwell {
		if command.kind != .G0 ||
		   !command.has_x || !command.has_y ||
		   command.has_z || command.has_e ||
		   !command.has_f ||
		   command.x != i64(operation.point_a.x) ||
		   command.y != i64(operation.point_a.y) ||
		   command.f != travel_feed ||
		   state.acceleration != travel_acceleration {
			return .Motion_Mismatch
		}
		state.positioned_xy = true
		state.x = command.x
		state.y = command.y
		return .None
	}
	if state.positioned_xy && state.z_hop_stage != 2 &&
	   (state.x != i64(operation.point_a.x) ||
	    state.y != i64(operation.point_a.y)) {
		return .Motion_Mismatch
	}
	expected_feed := klipper_feed_rate(operation.speed)
	expected_acceleration := i64(operation.acceleration)/1_000
	switch operation.kind {
	case .Retract, .Recover:
		if command.kind != .G1 ||
		   command.has_x || command.has_y || command.has_z ||
		   !command.has_e || !command.has_f ||
		   command.e_nm != operation.filament_delta_nm ||
		   command.f != expected_feed {
			return .Motion_Mismatch
		}
	case .Travel:
		travel_z := max(i64(0), i64(layer.z)+i64(operation.z_offset_um))
		if i64(operation.z_hop_um) > 0 {
			hop_z := i64(layer.z) + i64(operation.z_hop_um)
			switch state.z_hop_stage {
			case 0:
				if command.kind != .G0 ||
				   command.has_x || command.has_y ||
				   !command.has_z || command.has_e ||
				   !command.has_f ||
				   command.z != hop_z ||
				   command.f != expected_feed ||
				   state.acceleration != expected_acceleration {
					return .Motion_Mismatch
				}
				state.z = command.z
				state.physical_z = command.z
				state.z_hop_stage = 1
				return klipper_position_in_bounds(state^, profile)
			case 1:
				if command.kind != .G0 ||
				   !command.has_x || !command.has_y ||
				   command.has_z || command.has_e ||
				   !command.has_f ||
				   command.x != i64(operation.point_b.x) ||
				   command.y != i64(operation.point_b.y) ||
				   command.f != expected_feed ||
				   state.acceleration != expected_acceleration {
					return .Motion_Mismatch
				}
				state.x = command.x
				state.y = command.y
				state.z_hop_stage = 2
				return klipper_position_in_bounds(state^, profile)
			case 2:
				if command.kind != .G0 ||
				   command.has_x || command.has_y ||
				   !command.has_z || command.has_e ||
				   !command.has_f ||
				   command.z != travel_z ||
				   command.f != expected_feed ||
				   state.acceleration != expected_acceleration {
					return .Motion_Mismatch
				}
				state.z = i64(layer.z)
				state.physical_z = command.z
				state.z_hop_stage = 0
			case:
				return .Motion_Mismatch
			}
		} else {
			need_z_restore := state.physical_z != travel_z
			if command.kind != .G0 ||
			   !command.has_x || !command.has_y ||
			   command.has_z != need_z_restore ||
			   (need_z_restore && command.z != travel_z) ||
			   command.has_e ||
			   !command.has_f ||
			   command.x != i64(operation.point_b.x) ||
			   command.y != i64(operation.point_b.y) ||
			   command.f != expected_feed ||
			   state.acceleration != expected_acceleration {
				return .Motion_Mismatch
			}
			state.x = command.x
			state.y = command.y
			if need_z_restore {
				state.physical_z = command.z
			}
		}
	case .Extrude:
		expected_kind := Klipper_Parsed_Kind.G1
		if operation.arc == .CW {expected_kind = .G2}
		if operation.arc == .CCW {expected_kind = .G3}
		expected_arc := operation.arc != .None
		expected_target_z := max(i64(0), i64(layer.z) + i64(operation.z_offset_um))
		expected_z_change := expected_target_z != state.physical_z
		if command.kind != expected_kind ||
		   !command.has_x || !command.has_y ||
		   command.has_z != expected_z_change ||
		   (expected_z_change && command.z != expected_target_z) ||
		   !command.has_e ||
		   !command.has_f ||
		   command.has_i != expected_arc ||
		   command.has_j != expected_arc ||
		   command.x != i64(operation.point_b.x) ||
		   command.y != i64(operation.point_b.y) ||
		   (expected_arc && (command.i != i64(operation.arc_center.x)-i64(operation.point_a.x) ||
		                     command.j != i64(operation.arc_center.y)-i64(operation.point_a.y))) ||
		   command.e_nm != operation.filament_delta_nm ||
		   command.f != expected_feed ||
		   state.acceleration != expected_acceleration ||
		   state.fan_pwm != klipper_fan_pwm(operation.fan_ratio) {
			return .Motion_Mismatch
		}
		state.x = command.x
		state.y = command.y
		if expected_z_change {
			state.physical_z = command.z
		}
	case .Dwell, .Invalid:
		return .Motion_Mismatch
	}
	if command.has_e {
		if command.e_nm > 0 {
			report.positive_filament_nm += u128(command.e_nm)
		} else if command.e_nm < 0 {
			report.negative_filament_nm += u128(-command.e_nm)
		}
	}
	state.operation_index += 1
	report.motion_operation_count += 1
	return klipper_position_in_bounds(state^, profile)
}

klipper_validate_print_dwell :: proc(
	command: Klipper_Parsed_Command,
	motion: features.Motion_Plan_Result,
	state: ^Klipper_Validation_State,
	report: ^Klipper_Validation_Report,
) -> Klipper_Validation_Error {
	if !state.layer_active || !state.layer_z_emitted ||
	   !command.has_p || command.p <= 0 {
		return .Invalid_Sequence
	}
	operation, operation_ok :=
		klipper_current_operation(state^, motion)
	if !operation_ok || operation.kind != .Dwell ||
	   u64(command.p) != (operation.duration_us+999)/1_000 {
		return .Motion_Mismatch
	}
	report.dwell_ms += u64(command.p)
	state.operation_index += 1
	report.motion_operation_count += 1
	return .None
}

// After the last operation, END_PRINT is the only command: the printer's macro retracts,
// parks and shuts down.
klipper_validate_shutdown :: proc(
	command: Klipper_Parsed_Command,
	report: ^Klipper_Validation_Report,
) -> Klipper_Validation_Error {
	if command.kind == .Exclude_Object && !report.print_ended {
		return .None
	}
	if command.kind != .End_Print || report.print_ended {return .Invalid_Sequence}
	report.print_ended = true
	return .None
}

klipper_apply_acceleration :: proc(
	command: Klipper_Parsed_Command,
	profile: profiles.Resolved_Profiles,
	state: ^Klipper_Validation_State,
) -> Klipper_Validation_Error {
	if command.kind != .Set_Velocity_Limit {return .Invalid_Sequence}
	limit := i64(profile.printer.maximum_acceleration)/1_000
	if command.value <= 0 || command.value > limit {return .Machine_Bounds}
	state.acceleration = command.value
	return .None
}

klipper_apply_fan :: proc(
	command: Klipper_Parsed_Command,
	state: ^Klipper_Validation_State,
	report: ^Klipper_Validation_Report,
) -> Klipper_Validation_Error {
	if command.kind == .M107 {
		state.fan_pwm = 0
	} else if command.kind == .M106 &&
	          command.has_s &&
	          command.s > 0 &&
	          command.s <= 255 {
		state.fan_pwm = i32(command.s)
	} else {
		return .Invalid_Syntax
	}
	report.final_fan_pwm = state.fan_pwm
	return .None
}

klipper_current_operation :: proc(
	state: Klipper_Validation_State,
	motion: features.Motion_Plan_Result,
) -> (features.Motion_Operation, bool) {
	if !state.layer_active ||
	   u64(state.current_layer) >= u64(len(motion.layers)) {
		return {}, false
	}
	layer := motion.layers[state.current_layer]
	end := layer.operation_offset+u64(layer.operation_count)
	if state.operation_index < layer.operation_offset ||
	   state.operation_index >= end {
		return {}, false
	}
	return motion.operations[state.operation_index], true
}

klipper_current_layer_complete :: proc(
	state: Klipper_Validation_State,
	motion: features.Motion_Plan_Result,
) -> bool {
	if !state.layer_active ||
	   u64(state.current_layer) >= u64(len(motion.layers)) ||
	   !state.layer_z_emitted {
		return false
	}
	layer := motion.layers[state.current_layer]
	return state.operation_index ==
		layer.operation_offset+u64(layer.operation_count)
}

klipper_printing_complete :: proc(
	state: Klipper_Validation_State,
	motion: features.Motion_Plan_Result,
) -> bool {
	if len(motion.layers) == 0 {
		return state.startup == .Complete
	}
	return state.current_layer == u32(len(motion.layers)-1) &&
		klipper_current_layer_complete(state, motion)
}

klipper_position_in_bounds :: proc(
	state: Klipper_Validation_State,
	profile: profiles.Resolved_Profiles,
) -> Klipper_Validation_Error {
	if state.x < i64(profile.printer.axis_minimum_x) ||
	   state.x > i64(profile.printer.axis_maximum_x) ||
	   state.y < i64(profile.printer.axis_minimum_y) ||
	   state.y > i64(profile.printer.axis_maximum_y) ||
	   state.z < i64(profile.printer.axis_minimum_z) ||
	   state.z > i64(profile.printer.axis_maximum_z) {
		return .Machine_Bounds
	}
	return .None
}

klipper_expected_evidence :: proc(
	motion: features.Motion_Plan_Result,
	profile: profiles.Resolved_Profiles,
) -> (positive, negative: u128, dwell_ms: u64, ok: bool) {
	for operation in motion.operations {
		if operation.filament_delta_nm > 0 {
			if positive >
			   max(u128)-u128(operation.filament_delta_nm) {
				return 0, 0, 0, false
			}
			positive += u128(operation.filament_delta_nm)
		} else if operation.filament_delta_nm < 0 {
			value := u128(-operation.filament_delta_nm)
			if negative > max(u128)-value {
				return 0, 0, 0, false
			}
			negative += value
		}
		if operation.kind == .Dwell {
			value := (operation.duration_us+999)/1_000
			if dwell_ms > max(u64)-value {
				return 0, 0, 0, false
			}
			dwell_ms += value
		}
	}
	return positive, negative, dwell_ms, true
}

klipper_parse_command :: proc(
	line: string,
) -> (Klipper_Parsed_Command, Klipper_Validation_Error) {
	if len(line) == 0 {return {}, .Invalid_Syntax}
	// Fast path: 99.8% of commands are G0/G1/G2/G3 motion commands.
	if line[0] == ';' {
		if line == KLIPPER_HEADER {
			return {kind = .Header}, .None
		}
		if strings.has_prefix(line, ";LAYER:") {
			return klipper_parse_layer_comment(line)
		}
		return {}, .Unsupported_Command
	}
	tokens: [8]string
	token_count, token_ok := klipper_tokenize(line, tokens[:])
	if !token_ok || token_count == 0 {
		return {}, .Invalid_Syntax
	}
	result := Klipper_Parsed_Command{}
	t0 := tokens[0]
	if len(t0) == 2 && t0[0] == 'G' {
		switch t0[1] {
		case '1': result.kind = .G1
		case '0': result.kind = .G0
		case '2': result.kind = .G2
		case '3': result.kind = .G3
		case '4': result.kind = .G4
		case:     return {}, .Unsupported_Command
		}
	} else {
		switch t0 {
		case "G21":  result.kind = .G21
		case "G90":  result.kind = .G90
		case "M83":  result.kind = .M83
		case "M106": result.kind = .M106
		case "M107": result.kind = .M107
		case "START_PRINT", "END_PRINT", "SET_VELOCITY_LIMIT", "SET_PRINT_STATS_INFO":
			return klipper_parse_extended(tokens[:token_count])
		case "EXCLUDE_OBJECT_DEFINE", "EXCLUDE_OBJECT_START", "EXCLUDE_OBJECT_END":
			return {kind = .Exclude_Object}, .None
		case "PAUSE", "M600":
			return {kind = .Pause_Or_Filament}, .None
		case:
			return {}, .Unsupported_Command
		}
	}
	for token in tokens[1:token_count] {
		if len(token) < 2 {return {}, .Invalid_Syntax}
		value := token[1:]
		switch token[0] {
		case 'X':
			if result.has_x {return {}, .Invalid_Syntax}
			result.x, token_ok =
				klipper_parse_fixed_i64(value, 3)
			result.has_x = true
		case 'Y':
			if result.has_y {return {}, .Invalid_Syntax}
			result.y, token_ok =
				klipper_parse_fixed_i64(value, 3)
			result.has_y = true
		case 'Z':
			if result.has_z {return {}, .Invalid_Syntax}
			result.z, token_ok =
				klipper_parse_fixed_i64(value, 3)
			result.has_z = true
		case 'I':
			if result.has_i {return {}, .Invalid_Syntax}
			result.i, token_ok =
				klipper_parse_fixed_i64(value, 3)
			result.has_i = true
		case 'J':
			if result.has_j {return {}, .Invalid_Syntax}
			result.j, token_ok =
				klipper_parse_fixed_i64(value, 3)
			result.has_j = true
		case 'E':
			if result.has_e {return {}, .Invalid_Syntax}
			e_units: i64
			e_units, token_ok =
				klipper_parse_fixed_i64(value, 5)
			result.e_nm = i128(e_units)*10
			result.has_e = true
		case 'F':
			if result.has_f {return {}, .Invalid_Syntax}
			result.f, token_ok = klipper_parse_i64(value)
			result.has_f = true
		case 'S':
			if result.has_s {return {}, .Invalid_Syntax}
			result.s, token_ok = klipper_parse_i64(value)
			result.has_s = true
		case 'P':
			if result.has_p {return {}, .Invalid_Syntax}
			result.p, token_ok = klipper_parse_i64(value)
			result.has_p = true
		case 'R':
			if result.has_r {return {}, .Invalid_Syntax}
			result.r, token_ok = klipper_parse_i64(value)
			result.has_r = true
		case 'T':
			if result.has_t {return {}, .Invalid_Syntax}
			result.t, token_ok = klipper_parse_i64(value)
			result.has_t = true
		case:
			return {}, .Invalid_Syntax
		}
		if !token_ok {return {}, .Invalid_Syntax}
	}
	if !klipper_command_parameters_valid(result, token_count) {
		return {}, .Invalid_Syntax
	}
	return result, .None
}

klipper_command_parameters_valid :: proc(
	command: Klipper_Parsed_Command,
	token_count: int,
) -> bool {
	parameter_count :=
		int(command.has_x)+int(command.has_y)+int(command.has_z)+
		int(command.has_i)+int(command.has_j)+
		int(command.has_e)+int(command.has_f)+int(command.has_s)+
		int(command.has_p)+int(command.has_r)+int(command.has_t)
	if token_count != parameter_count+1 {return false}
	switch command.kind {
	case .G21, .G90, .M83, .M107:
		return parameter_count == 0
	case .G0, .G1:
		return (command.has_x || command.has_y ||
			command.has_z || command.has_e) &&
			command.has_f &&
			!command.has_i && !command.has_j &&
			!command.has_s && !command.has_p &&
			!command.has_r && !command.has_t
	case .G2, .G3:
		return command.has_x && command.has_y &&
			command.has_i && command.has_j &&
			command.has_e && command.has_f &&
			!command.has_s && !command.has_p &&
			!command.has_r && !command.has_t
	case .G4:
		return command.has_p && parameter_count == 1
	case .M106:
		return command.has_s && parameter_count == 1
	case .Header, .Layer, .Invalid, .Start_Print, .End_Print,
	     .Set_Velocity_Limit, .Print_Stats_Total, .Print_Stats_Current,
	     .Exclude_Object, .Pause_Or_Filament:
		return false
	}
	return false
}

// Parses a Klipper extended command: a name followed by KEY=VALUE parameters in the order
// the emitter writes them.
klipper_parse_extended :: proc(
	tokens: []string,
) -> (Klipper_Parsed_Command, Klipper_Validation_Error) {
	parameter :: proc(token, key: string) -> (string, bool) {
		if len(token) <= len(key)+1 || token[:len(key)] != key || token[len(key)] != '=' {return "", false}
		return token[len(key)+1:], true
	}
	integer :: proc(token, key: string) -> (value: i64, ok: bool) {
		text := parameter(token, key) or_return
		return klipper_parse_i64(text)
	}
	coordinate :: proc(token, key: string) -> (value: i64, ok: bool) {
		text := parameter(token, key) or_return
		return klipper_parse_fixed_i64(text, 3)
	}
	result: Klipper_Parsed_Command
	ok := true
	switch tokens[0] {
	case "END_PRINT":
		result.kind = .End_Print
		ok = len(tokens) == 1
	case "SET_VELOCITY_LIMIT":
		result.kind = .Set_Velocity_Limit
		ok = len(tokens) == 2
		if ok {result.value, ok = integer(tokens[1], "ACCEL")}
	case "SET_PRINT_STATS_INFO":
		ok = len(tokens) == 2
		if !ok {break}
		total, total_ok := integer(tokens[1], "TOTAL_LAYER")
		current, current_ok := integer(tokens[1], "CURRENT_LAYER")
		if total_ok {
			result = {kind = .Print_Stats_Total, value = total}
		} else if current_ok {
			result = {kind = .Print_Stats_Current, value = current}
		} else {
			ok = false
		}
	case "START_PRINT":
		result.kind = .Start_Print
		ok = len(tokens) == 8
		if !ok {break}
		temperature_ok, other_ok, bed_ok: bool
		result.extruder_temperature, temperature_ok = integer(tokens[1], "EXTRUDER_TEMP")
		result.extruder_other_temperature, other_ok = integer(tokens[2], "EXTRUDER_OTHER_LAYER_TEMP")
		result.bed_temperature, bed_ok = integer(tokens[3], "BED_TEMP")
		ok = temperature_ok && other_ok && bed_ok
		keys := [4]string{"X0", "Y0", "X1", "Y1"}
		for key, index in keys {
			value, value_ok := coordinate(tokens[4+index], key)
			result.area[index] = value
			ok = ok && value_ok
		}
	case:
		return {}, .Unsupported_Command
	}
	if !ok {return {}, .Invalid_Syntax}
	return result, .None
}

klipper_parse_layer_comment :: proc(
	line: string,
) -> (Klipper_Parsed_Command, Klipper_Validation_Error) {
	cursor := len(";LAYER:")
	index_start := cursor
	for cursor < len(line) && line[cursor] >= '0' &&
	    line[cursor] <= '9' {
		cursor += 1
	}
	if cursor == index_start || cursor+3 > len(line) ||
	   line[cursor:cursor+3] != " Z:" {
		return {}, .Invalid_Syntax
	}
	index_value, index_ok := klipper_parse_i64(line[index_start:cursor])
	z_value, z_ok := klipper_parse_fixed_i64(line[cursor+3:], 3)
	if !index_ok || !z_ok ||
	   index_value < 0 || index_value > i64(max(u32)) {
		return {}, .Invalid_Syntax
	}
	return {
		kind = .Layer,
		layer_index = u32(index_value),
		layer_z = z_value,
	}, .None
}

klipper_tokenize :: proc(line: string, tokens: []string) -> (int, bool) {
	if len(line) == 0 || line[0] == ' ' ||
	   line[len(line)-1] == ' ' {
		return 0, false
	}
	count := 0
	start := 0
	for index in 0..=len(line) {
		if index < len(line) && line[index] != ' ' {continue}
		if index == start || count >= len(tokens) {
			return 0, false
		}
		tokens[count] = line[start:index]
		count += 1
		start = index+1
	}
	return count, true
}

klipper_parse_i64 :: #force_inline proc(text: string) -> (i64, bool) {
	n := len(text)
	if n == 0 {return 0, false}
	negative := false
	cursor := 0
	if text[0] == '-' {
		negative = true
		cursor = 1
		if cursor == n {return 0, false}
	}
	digits := n - cursor
	if digits > 1 && text[cursor] == '0' {
		return 0, false
	}
	value: u64
	if digits <= 18 {
		// <= 18 decimal digits cannot overflow i64; skip per-digit division check.
		for cursor < n {
			d := text[cursor] - '0'
			if d > 9 {return 0, false}
			value = value*10 + u64(d)
			cursor += 1
		}
		return -i64(value) if negative else i64(value), true
	}
	for cursor < n {
		digit := text[cursor]
		if digit < '0' || digit > '9' {
			return 0, false
		}
		added := u64(digit-'0')
		if value > (u64(max(i64))+u64(negative)-added)/10 {
			return 0, false
		}
		value = value*10+added
		cursor += 1
	}
	if negative {
		if value == u64(max(i64))+1 {return min(i64), true}
		return -i64(value), true
	}
	return i64(value), true
}

klipper_parse_fixed_i64 :: #force_inline proc(
	text: string,
	decimal_places: int,
) -> (i64, bool) {
	n := len(text)
	if n < decimal_places+2 {return 0, false}
	negative := text[0] == '-'
	cursor := 1 if negative else 0
	dot := n - decimal_places - 1
	if dot <= cursor || text[dot] != '.' {
		return 0, false
	}
	whole_len := dot - cursor
	if whole_len > 1 && text[cursor] == '0' {return 0, false}
	// Fast path for normal coordinates (<= 12 integer digits, 3 or 5 decimals: zero divisions).
	if whole_len <= 12 && (decimal_places == 3 || decimal_places == 5) {
		whole: i64
		for i in cursor..<dot {
			d := text[i] - '0'
			if d > 9 {return 0, false}
			whole = whole*10 + i64(d)
		}
		fraction: i64
		for i in dot+1..<n {
			d := text[i] - '0'
			if d > 9 {return 0, false}
			fraction = fraction*10 + i64(d)
		}
		scale: i64 = 1_000 if decimal_places == 3 else 100_000
		value := whole*scale + fraction
		return -value if negative else value, true
	}
	whole, whole_ok := klipper_parse_i64(text[cursor:dot])
	if !whole_ok || whole < 0 {return 0, false}
	fraction: i64
	for index in dot+1..<n {
		digit := text[index]
		if digit < '0' || digit > '9' {return 0, false}
		fraction = fraction*10+i64(digit-'0')
	}
	scale := i64(1)
	for _ in 0..<decimal_places {scale *= 10}
	if whole > (max(i64)-fraction)/scale {
		return 0, false
	}
	value := whole*scale+fraction
	if negative {value = -value}
	return value, true
}
