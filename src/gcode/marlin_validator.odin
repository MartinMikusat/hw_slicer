package gcode

import "core:strings"

import contracts "../contracts"
import features "../features"
import profiles "../profiles"

Marlin_Validation_Error :: enum u8 {
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

Marlin_Validation_Report :: struct {
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
	steppers_disabled:     bool,
}

Marlin_Parsed_Kind :: enum u8 {
	Invalid,
	Header,
	Layer,
	G21,
	G28,
	G29,
	G90,
	G0,
	G1,
	G4,
	M83,
	M84,
	M104,
	M106,
	M107,
	M109,
	M140,
	M190,
	M204,
	M420,
}

Marlin_Parsed_Command :: struct {
	kind:        Marlin_Parsed_Kind,
	layer_index: u32,
	layer_z:     i64,
	has_x:       bool,
	has_y:       bool,
	has_z:       bool,
	has_e:       bool,
	has_f:       bool,
	has_s:       bool,
	has_p:       bool,
	has_r:       bool,
	has_t:       bool,
	x:           i64,
	y:           i64,
	z:           i64,
	e_nm:        i128,
	f:           i64,
	s:           i64,
	p:           i64,
	r:           i64,
	t:           i64,
}

Marlin_Startup_Stage :: enum u8 {
	Header,
	Millimetres,
	Absolute_Coordinates,
	Relative_Extrusion,
	Fan_Off,
	Start_Bed,
	Home,
	Wait_Bed,
	Level,
	Wait_Nozzle,
	Complete,
}

Marlin_Validation_State :: struct {
	startup:              Marlin_Startup_Stage,
	current_layer:        u32,
	layer_active:         bool,
	layer_z_emitted:      bool,
	operation_index:      u64,
	positioned_xy:        bool,
	x:                    i64,
	y:                    i64,
	z:                    i64,
	print_acceleration:   i64,
	travel_acceleration:  i64,
	retract_acceleration: i64,
	fan_pwm:              i32,
	shutdown_move_step:   u8,
	shutdown_control_step: u8,
}

marlin_validate :: proc(
	bytes: []u8,
	profile: profiles.Resolved_Profiles,
	motion: features.Motion_Plan_Result,
) -> (Marlin_Validation_Report, Marlin_Validation_Error) {
	if len(bytes) == 0 || bytes[len(bytes)-1] != '\n' ||
	   !marlin_motion_valid(motion, profile) {
		return {}, .Invalid_Encoding
	}
	state := Marlin_Validation_State{
		startup = .Header,
		current_layer = max(u32),
		print_acceleration = -1,
		travel_acceleration = -1,
		retract_acceleration = -1,
		fan_pwm = -1,
	}
	report := Marlin_Validation_Report{}
	line_start := 0
	for byte, byte_index in bytes {
		if byte == '\r' || byte == 0 ||
		   byte < 0x20 && byte != '\n' ||
		   byte > 0x7e {
			return {}, .Invalid_Encoding
		}
		if byte != '\n' {continue}
		if byte_index == line_start {
			return {}, .Invalid_Encoding
		}
		line := string(bytes[line_start:byte_index])
		command, parse_error := marlin_parse_command(line)
		if parse_error != .None {return {}, parse_error}
		report.command_count += 1
		if state.startup != .Complete {
			startup_error := marlin_validate_startup(
				command,
				profile,
				&state,
				&report,
			)
			if startup_error != .None {
				return {}, startup_error
			}
		} else if marlin_printing_complete(state, motion) {
			shutdown_error := marlin_validate_shutdown(
				command,
				profile,
				motion,
				&state,
				&report,
			)
			if shutdown_error != .None {
				return {}, shutdown_error
			}
		} else {
			print_error := marlin_validate_print_command(
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
	   !marlin_printing_complete(state, motion) ||
	   state.shutdown_control_step != 4 {
		return {}, .Final_State
	}
	expected_positive, expected_negative, expected_dwell, evidence_ok :=
		marlin_expected_evidence(motion, profile)
	if !evidence_ok ||
	   report.layer_count != u32(len(motion.layers)) ||
	   report.motion_operation_count != u64(len(motion.operations)) ||
	   report.positive_filament_nm != expected_positive ||
	   report.negative_filament_nm != expected_negative ||
	   report.dwell_ms != expected_dwell ||
	   report.final_fan_pwm != 0 ||
	   report.nozzle_temperature != 0 ||
	   report.bed_temperature != 0 ||
	   !report.steppers_disabled {
		return {}, .Final_State
	}
	report.final_x = contracts.Micrometres(state.x)
	report.final_y = contracts.Micrometres(state.y)
	report.final_z = contracts.Micrometres(state.z)
	return report, .None
}

marlin_validate_startup :: proc(
	command: Marlin_Parsed_Command,
	profile: profiles.Resolved_Profiles,
	state: ^Marlin_Validation_State,
	report: ^Marlin_Validation_Report,
) -> Marlin_Validation_Error {
	marlin_skip_startup_stages(state, profile)
	switch state.startup {
	case .Header:
		if command.kind != .Header {return .Invalid_Sequence}
		state.startup = .Millimetres
	case .Millimetres:
		if command.kind != .G21 {return .Invalid_Sequence}
		state.startup = .Absolute_Coordinates
	case .Absolute_Coordinates:
		if command.kind != .G90 {return .Invalid_Sequence}
		state.startup = .Relative_Extrusion
	case .Relative_Extrusion:
		if command.kind != .M83 {return .Invalid_Sequence}
		state.startup = .Fan_Off
	case .Fan_Off:
		if command.kind != .M107 {return .Invalid_Sequence}
		state.fan_pwm = 0
		report.final_fan_pwm = 0
		state.startup = .Start_Bed
	case .Start_Bed:
		if command.kind != .M140 ||
		   !command.has_s ||
		   command.s != i64(profile.process.source.bed_temperature) {
			return .Invalid_Sequence
		}
		report.bed_temperature = i32(command.s)
		state.startup = .Home
	case .Home:
		if command.kind != .G28 {return .Invalid_Sequence}
		state.startup = .Wait_Bed
	case .Wait_Bed:
		if command.kind != .M190 ||
		   !command.has_s ||
		   command.s != i64(profile.process.source.bed_temperature) {
			return .Invalid_Sequence
		}
		state.startup = .Level
	case .Level:
		switch profile.printer.bed_leveling {
		case .Probe_Before_Print:
			if command.kind != .G29 {return .Invalid_Sequence}
		case .Restore_Stored_Mesh:
			if command.kind != .M420 ||
			   !command.has_s || command.s != 1 {
				return .Invalid_Sequence
			}
		case .None, .Invalid:
			return .Invalid_Sequence
		}
		state.startup = .Wait_Nozzle
	case .Wait_Nozzle:
		if command.kind != .M109 ||
		   !command.has_s ||
		   command.s != i64(profile.process.source.nozzle_temperature) {
			return .Invalid_Sequence
		}
		report.nozzle_temperature = i32(command.s)
		state.startup = .Complete
	case .Complete:
		return .Invalid_Sequence
	}
	marlin_skip_startup_stages(state, profile)
	return .None
}

marlin_skip_startup_stages :: proc(
	state: ^Marlin_Validation_State,
	profile: profiles.Resolved_Profiles,
) {
	for {
		if state.startup == .Start_Bed &&
		   i32(profile.process.source.bed_temperature) == 0 {
			state.startup = .Home
			continue
		}
		if state.startup == .Wait_Bed &&
		   i32(profile.process.source.bed_temperature) == 0 {
			state.startup = .Level
			continue
		}
		if state.startup == .Level &&
		   profile.printer.bed_leveling == .None {
			state.startup = .Wait_Nozzle
			continue
		}
		break
	}
}

marlin_validate_print_command :: proc(
	command: Marlin_Parsed_Command,
	profile: profiles.Resolved_Profiles,
	motion: features.Motion_Plan_Result,
	state: ^Marlin_Validation_State,
	report: ^Marlin_Validation_Report,
) -> Marlin_Validation_Error {
	switch command.kind {
	case .Layer:
		if state.layer_active &&
		   !marlin_current_layer_complete(state^, motion) {
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
		state.layer_z_emitted = false
		report.layer_count += 1
		return .None
	case .M204:
		return marlin_apply_acceleration(command, profile, state)
	case .M106, .M107:
		return marlin_apply_fan(command, state, report)
	case .G0, .G1:
		return marlin_validate_print_move(
			command,
			profile,
			motion,
			state,
			report,
		)
	case .G4:
		return marlin_validate_print_dwell(
			command,
			motion,
			state,
			report,
		)
	case .Invalid, .Header, .G21, .G28, .G29, .G90, .M83, .M84,
	     .M104, .M109, .M140, .M190, .M420:
		return .Invalid_Sequence
	}
	return .Invalid_Sequence
}

marlin_validate_print_move :: proc(
	command: Marlin_Parsed_Command,
	profile: profiles.Resolved_Profiles,
	motion: features.Motion_Plan_Result,
	state: ^Marlin_Validation_State,
	report: ^Marlin_Validation_Report,
) -> Marlin_Validation_Error {
	if !state.layer_active {return .Invalid_Sequence}
	layer := motion.layers[state.current_layer]
	travel_feed :=
		marlin_feed_rate(profile.process.source.travel.speed)
	travel_acceleration :=
		i64(profile.process.source.travel.acceleration)/1_000
	if !state.layer_z_emitted {
		if command.kind != .G0 ||
		   command.has_x || command.has_y || command.has_e ||
		   !command.has_z || !command.has_f ||
		   command.z != i64(layer.z) ||
		   command.f != travel_feed ||
		   state.travel_acceleration != travel_acceleration {
			return .Motion_Mismatch
		}
		state.z = command.z
		state.layer_z_emitted = true
		return .None
	}
	operation, operation_ok :=
		marlin_current_operation(state^, motion)
	if !operation_ok {return .Invalid_Sequence}
	if !state.positioned_xy && operation.kind != .Dwell {
		if command.kind != .G0 ||
		   !command.has_x || !command.has_y ||
		   command.has_z || command.has_e ||
		   !command.has_f ||
		   command.x != i64(operation.point_a.x) ||
		   command.y != i64(operation.point_a.y) ||
		   command.f != travel_feed ||
		   state.travel_acceleration != travel_acceleration {
			return .Motion_Mismatch
		}
		state.positioned_xy = true
		state.x = command.x
		state.y = command.y
		return .None
	}
	if state.positioned_xy &&
	   (state.x != i64(operation.point_a.x) ||
	    state.y != i64(operation.point_a.y)) {
		return .Motion_Mismatch
	}
	expected_feed := marlin_feed_rate(operation.speed)
	expected_acceleration := i64(operation.acceleration)/1_000
	switch operation.kind {
	case .Retract, .Recover:
		if command.kind != .G1 ||
		   command.has_x || command.has_y || command.has_z ||
		   !command.has_e || !command.has_f ||
		   command.e_nm != operation.filament_delta_nm ||
		   command.f != expected_feed ||
		   state.retract_acceleration != expected_acceleration {
			return .Motion_Mismatch
		}
	case .Travel:
		if command.kind != .G0 ||
		   !command.has_x || !command.has_y ||
		   command.has_z || command.has_e ||
		   !command.has_f ||
		   command.x != i64(operation.point_b.x) ||
		   command.y != i64(operation.point_b.y) ||
		   command.f != expected_feed ||
		   state.travel_acceleration != expected_acceleration {
			return .Motion_Mismatch
		}
		state.x = command.x
		state.y = command.y
	case .Extrude:
		if command.kind != .G1 ||
		   !command.has_x || !command.has_y ||
		   command.has_z || !command.has_e ||
		   !command.has_f ||
		   command.x != i64(operation.point_b.x) ||
		   command.y != i64(operation.point_b.y) ||
		   command.e_nm != operation.filament_delta_nm ||
		   command.f != expected_feed ||
		   state.print_acceleration != expected_acceleration ||
		   state.fan_pwm != marlin_fan_pwm(operation.fan_ratio) {
			return .Motion_Mismatch
		}
		state.x = command.x
		state.y = command.y
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
	return marlin_position_in_bounds(state^, profile)
}

marlin_validate_print_dwell :: proc(
	command: Marlin_Parsed_Command,
	motion: features.Motion_Plan_Result,
	state: ^Marlin_Validation_State,
	report: ^Marlin_Validation_Report,
) -> Marlin_Validation_Error {
	if !state.layer_active || !state.layer_z_emitted ||
	   !command.has_p || command.p <= 0 {
		return .Invalid_Sequence
	}
	operation, operation_ok :=
		marlin_current_operation(state^, motion)
	if !operation_ok || operation.kind != .Dwell ||
	   u64(command.p) != (operation.duration_us+999)/1_000 {
		return .Motion_Mismatch
	}
	report.dwell_ms += u64(command.p)
	state.operation_index += 1
	report.motion_operation_count += 1
	return .None
}

marlin_validate_shutdown :: proc(
	command: Marlin_Parsed_Command,
	profile: profiles.Resolved_Profiles,
	motion: features.Motion_Plan_Result,
	state: ^Marlin_Validation_State,
	report: ^Marlin_Validation_Report,
) -> Marlin_Validation_Error {
	park := profile.printer.park_after_print &&
		motion.extrusion_count > 0
	retraction_feed :=
		marlin_feed_rate(profile.process.source.retraction_speed)
	retraction_acceleration :=
		i64(profile.process.source.retraction_acceleration)/1_000
	travel_feed :=
		marlin_feed_rate(profile.process.source.travel.speed)
	travel_acceleration :=
		i64(profile.process.source.travel.acceleration)/1_000
	if park && state.shutdown_move_step < 3 {
		if command.kind == .M204 {
			return marlin_apply_acceleration(command, profile, state)
		}
		if command.kind != .G0 && command.kind != .G1 {
			return .Invalid_Sequence
		}
		switch state.shutdown_move_step {
		case 0:
			expected_e :=
				-i128(i64(profile.process.source.retraction_distance))*1_000
			if command.kind != .G1 ||
			   command.has_x || command.has_y || command.has_z ||
			   !command.has_e || !command.has_f ||
			   command.e_nm != expected_e ||
			   command.f != retraction_feed ||
			   state.retract_acceleration != retraction_acceleration {
				return .Motion_Mismatch
			}
			report.negative_filament_nm += u128(-expected_e)
		case 1:
			expected_z :=
				state.z+i64(profile.printer.park_z_lift)
			if command.kind != .G0 ||
			   command.has_x || command.has_y || command.has_e ||
			   !command.has_z || !command.has_f ||
			   command.z != expected_z ||
			   command.f != travel_feed ||
			   state.travel_acceleration != travel_acceleration {
				return .Motion_Mismatch
			}
			state.z = command.z
		case 2:
			if command.kind != .G0 ||
			   !command.has_x || !command.has_y ||
			   command.has_z || command.has_e ||
			   !command.has_f ||
			   command.x != i64(profile.printer.park_x) ||
			   command.y != i64(profile.printer.park_y) ||
			   command.f != travel_feed {
				return .Motion_Mismatch
			}
			state.x = command.x
			state.y = command.y
		}
		state.shutdown_move_step += 1
		return marlin_position_in_bounds(state^, profile)
	}
	switch state.shutdown_control_step {
	case 0:
		if command.kind != .M107 {return .Invalid_Sequence}
		state.fan_pwm = 0
		report.final_fan_pwm = 0
	case 1:
		if command.kind != .M104 ||
		   !command.has_s || command.s != 0 {
			return .Invalid_Sequence
		}
		report.nozzle_temperature = 0
	case 2:
		if command.kind != .M140 ||
		   !command.has_s || command.s != 0 {
			return .Invalid_Sequence
		}
		report.bed_temperature = 0
	case 3:
		if command.kind != .M84 {return .Invalid_Sequence}
		report.steppers_disabled = true
	case:
		return .Invalid_Sequence
	}
	state.shutdown_control_step += 1
	return .None
}

marlin_apply_acceleration :: proc(
	command: Marlin_Parsed_Command,
	profile: profiles.Resolved_Profiles,
	state: ^Marlin_Validation_State,
) -> Marlin_Validation_Error {
	if command.kind != .M204 {
		return .Invalid_Sequence
	}
	count := u8(command.has_p)+u8(command.has_r)+u8(command.has_t)
	if count != 1 {return .Invalid_Syntax}
	value: i64
	limit := i64(profile.printer.maximum_acceleration)/1_000
	if command.has_p {
		value = command.p
		state.print_acceleration = value
	} else if command.has_t {
		value = command.t
		state.travel_acceleration = value
	} else {
		value = command.r
		limit =
			i64(profile.printer.maximum_extruder_acceleration)/1_000
		state.retract_acceleration = value
	}
	if value <= 0 || value > limit {return .Machine_Bounds}
	return .None
}

marlin_apply_fan :: proc(
	command: Marlin_Parsed_Command,
	state: ^Marlin_Validation_State,
	report: ^Marlin_Validation_Report,
) -> Marlin_Validation_Error {
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

marlin_current_operation :: proc(
	state: Marlin_Validation_State,
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

marlin_current_layer_complete :: proc(
	state: Marlin_Validation_State,
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

marlin_printing_complete :: proc(
	state: Marlin_Validation_State,
	motion: features.Motion_Plan_Result,
) -> bool {
	if len(motion.layers) == 0 {
		return state.startup == .Complete
	}
	return state.current_layer == u32(len(motion.layers)-1) &&
		marlin_current_layer_complete(state, motion)
}

marlin_position_in_bounds :: proc(
	state: Marlin_Validation_State,
	profile: profiles.Resolved_Profiles,
) -> Marlin_Validation_Error {
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

marlin_expected_evidence :: proc(
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
	if profile.printer.park_after_print && motion.extrusion_count > 0 {
		value :=
			u128(i64(profile.process.source.retraction_distance))*1_000
		if negative > max(u128)-value {
			return 0, 0, 0, false
		}
		negative += value
	}
	return positive, negative, dwell_ms, true
}

marlin_parse_command :: proc(
	line: string,
) -> (Marlin_Parsed_Command, Marlin_Validation_Error) {
	if line == "; hw_slicer conservative marlin" {
		return {kind = .Header}, .None
	}
	if strings.has_prefix(line, ";LAYER:") {
		return marlin_parse_layer_comment(line)
	}
	tokens: [8]string
	token_count, token_ok := marlin_tokenize(line, tokens[:])
	if !token_ok || token_count == 0 {
		return {}, .Invalid_Syntax
	}
	result := Marlin_Parsed_Command{}
	switch tokens[0] {
	case "G0":   result.kind = .G0
	case "G1":   result.kind = .G1
	case "G4":   result.kind = .G4
	case "G21":  result.kind = .G21
	case "G28":  result.kind = .G28
	case "G29":  result.kind = .G29
	case "G90":  result.kind = .G90
	case "M83":  result.kind = .M83
	case "M84":  result.kind = .M84
	case "M104": result.kind = .M104
	case "M106": result.kind = .M106
	case "M107": result.kind = .M107
	case "M109": result.kind = .M109
	case "M140": result.kind = .M140
	case "M190": result.kind = .M190
	case "M204": result.kind = .M204
	case "M420": result.kind = .M420
	case:
		return {}, .Unsupported_Command
	}
	for token in tokens[1:token_count] {
		if len(token) < 2 {return {}, .Invalid_Syntax}
		value := token[1:]
		switch token[0] {
		case 'X':
			if result.has_x {return {}, .Invalid_Syntax}
			result.x, token_ok =
				marlin_parse_fixed_i64(value, 3)
			result.has_x = true
		case 'Y':
			if result.has_y {return {}, .Invalid_Syntax}
			result.y, token_ok =
				marlin_parse_fixed_i64(value, 3)
			result.has_y = true
		case 'Z':
			if result.has_z {return {}, .Invalid_Syntax}
			result.z, token_ok =
				marlin_parse_fixed_i64(value, 3)
			result.has_z = true
		case 'E':
			if result.has_e {return {}, .Invalid_Syntax}
			e_units: i64
			e_units, token_ok =
				marlin_parse_fixed_i64(value, 5)
			result.e_nm = i128(e_units)*10
			result.has_e = true
		case 'F':
			if result.has_f {return {}, .Invalid_Syntax}
			result.f, token_ok = marlin_parse_i64(value)
			result.has_f = true
		case 'S':
			if result.has_s {return {}, .Invalid_Syntax}
			result.s, token_ok = marlin_parse_i64(value)
			result.has_s = true
		case 'P':
			if result.has_p {return {}, .Invalid_Syntax}
			result.p, token_ok = marlin_parse_i64(value)
			result.has_p = true
		case 'R':
			if result.has_r {return {}, .Invalid_Syntax}
			result.r, token_ok = marlin_parse_i64(value)
			result.has_r = true
		case 'T':
			if result.has_t {return {}, .Invalid_Syntax}
			result.t, token_ok = marlin_parse_i64(value)
			result.has_t = true
		case:
			return {}, .Invalid_Syntax
		}
		if !token_ok {return {}, .Invalid_Syntax}
	}
	if !marlin_command_parameters_valid(result, token_count) {
		return {}, .Invalid_Syntax
	}
	return result, .None
}

marlin_command_parameters_valid :: proc(
	command: Marlin_Parsed_Command,
	token_count: int,
) -> bool {
	parameter_count :=
		int(command.has_x)+int(command.has_y)+int(command.has_z)+
		int(command.has_e)+int(command.has_f)+int(command.has_s)+
		int(command.has_p)+int(command.has_r)+int(command.has_t)
	if token_count != parameter_count+1 {return false}
	switch command.kind {
	case .G21, .G28, .G29, .G90, .M83, .M84, .M107:
		return parameter_count == 0
	case .G0, .G1:
		return (command.has_x || command.has_y ||
			command.has_z || command.has_e) &&
			command.has_f &&
			!command.has_s && !command.has_p &&
			!command.has_r && !command.has_t
	case .G4:
		return command.has_p && parameter_count == 1
	case .M104, .M106, .M109, .M140, .M190, .M420:
		return command.has_s && parameter_count == 1
	case .M204:
		return parameter_count == 1 &&
			(command.has_p || command.has_r || command.has_t)
	case .Header, .Layer, .Invalid:
		return false
	}
	return false
}

marlin_parse_layer_comment :: proc(
	line: string,
) -> (Marlin_Parsed_Command, Marlin_Validation_Error) {
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
	index_value, index_ok := marlin_parse_i64(line[index_start:cursor])
	z_value, z_ok := marlin_parse_fixed_i64(line[cursor+3:], 3)
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

marlin_tokenize :: proc(line: string, tokens: []string) -> (int, bool) {
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

marlin_parse_i64 :: proc(text: string) -> (i64, bool) {
	if len(text) == 0 {return 0, false}
	negative := false
	cursor := 0
	if text[0] == '-' {
		negative = true
		cursor = 1
		if cursor == len(text) {return 0, false}
	}
	if len(text)-cursor > 1 && text[cursor] == '0' {
		return 0, false
	}
	value: u64
	for cursor < len(text) {
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

marlin_parse_fixed_i64 :: proc(
	text: string,
	decimal_places: int,
) -> (i64, bool) {
	if len(text) < decimal_places+2 {return 0, false}
	negative := text[0] == '-'
	cursor := 1 if negative else 0
	dot := len(text)-decimal_places-1
	if dot <= cursor || text[dot] != '.' {
		return 0, false
	}
	whole, whole_ok := marlin_parse_i64(text[cursor:dot])
	if !whole_ok || whole < 0 {return 0, false}
	fraction: i64
	for index in dot+1..<len(text) {
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
