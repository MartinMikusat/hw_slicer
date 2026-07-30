package gcode

import "core:fmt"
import "core:strings"

import contracts "../contracts"
import features "../features"
import profiles "../profiles"

MARLIN_EMITTER_SCHEMA_VERSION :: u32(1)

Marlin_Command_Kind :: enum u8 {
	Invalid,
	Comment,
	Set_Millimetres,
	Set_Absolute_Coordinates,
	Set_Relative_Extrusion,
	Set_Bed_Temperature,
	Wait_Bed_Temperature,
	Wait_Nozzle_Temperature,
	Home_All_Axes,
	Probe_Bed,
	Restore_Bed_Mesh,
	Set_Print_Acceleration,
	Set_Travel_Acceleration,
	Set_Retract_Acceleration,
	Set_Fan,
	Move,
	Dwell,
	Set_Nozzle_Temperature,
	Disable_Steppers,
}

Marlin_Command_Record :: struct {
	stable_id:          contracts.Stable_ID,
	command_index:      u32,
	kind:               Marlin_Command_Kind,
	byte_offset:        u64,
	byte_count:         u32,
	source_operation_id: contracts.Stable_ID,
	layer_index:        u32,
}

Marlin_Result :: struct {
	schema_version:             u32,
	bytes:                      []u8,
	commands:                   []Marlin_Command_Record,
	layer_count:                u32,
	motion_operation_count:     u64,
	positive_filament_nm:       u128,
	negative_filament_nm:       u128,
	emitted_dwell_ms:           u64,
	shutdown_retraction_nm:     u64,
	final_x:                    contracts.Micrometres,
	final_y:                    contracts.Micrometres,
	final_z:                    contracts.Micrometres,
}

Marlin_Limits :: struct {
	max_commands: u64,
	max_bytes:    u64,
}

DEFAULT_MARLIN_LIMITS :: Marlin_Limits{
	max_commands = 20_000_000_000,
	max_bytes = 16*1024*1024*1024,
}

Marlin_Error :: enum u8 {
	None,
	Invalid_Profile,
	Invalid_Motion,
	Command_Limit,
	Byte_Limit,
	Allocation_Failed,
	Arithmetic,
}

Marlin_State :: struct {
	print_acceleration:   i64,
	travel_acceleration:  i64,
	retract_acceleration: i64,
	fan_pwm:              i32,
	positioned_xy:        bool,
	x:                    contracts.Micrometres,
	y:                    contracts.Micrometres,
	z:                    contracts.Micrometres,
}

marlin_emit :: proc(
	motion: features.Motion_Plan_Result,
	profile: profiles.Resolved_Profiles,
	limits := DEFAULT_MARLIN_LIMITS,
	allocator := context.allocator,
) -> (Marlin_Result, Marlin_Error) {
	resolved, resolve_error := profiles.profiles_resolve(
		profile.printer,
		profile.material,
		profile.process.source,
		profile.dialect,
	)
	if resolve_error != .None || resolved != profile {
		return {}, .Invalid_Profile
	}
	if !marlin_motion_valid(motion, profile) {
		return {}, .Invalid_Motion
	}
	maximum_commands :=
		u64(32)+u64(len(motion.layers))*4+
		u64(len(motion.operations))*3
	if maximum_commands < u64(len(motion.operations)) ||
	   maximum_commands > limits.max_commands ||
	   maximum_commands > u64(max(int)) {
		return {}, .Command_Limit
	}
	estimated_bytes :=
		u64(4_096)+u64(len(motion.layers))*128+
		u64(len(motion.operations))*192
	if estimated_bytes < u64(len(motion.operations)) ||
	   estimated_bytes > limits.max_bytes ||
	   estimated_bytes > u64(max(int)) {
		return {}, .Byte_Limit
	}

	builder, builder_error := strings.builder_make(
		0,
		int(estimated_bytes),
		allocator,
	)
	if builder_error != nil {return {}, .Allocation_Failed}
	defer strings.builder_destroy(&builder)
	commands :=
		make([]Marlin_Command_Record, int(maximum_commands), allocator)
	if maximum_commands > 0 && commands == nil {
		return {}, .Allocation_Failed
	}
	command_write := 0
	result := Marlin_Result{
		schema_version = MARLIN_EMITTER_SCHEMA_VERSION,
		layer_count = u32(len(motion.layers)),
		motion_operation_count = u64(len(motion.operations)),
	}
	state := Marlin_State{
		print_acceleration = -1,
		travel_acceleration = -1,
		retract_acceleration = -1,
		fan_pwm = -1,
	}

	if !marlin_write_literal(
		&builder,
		commands,
		&command_write,
		.Comment,
		"; hw_slicer conservative marlin\n",
	) ||
	   !marlin_write_literal(
		&builder,
		commands,
		&command_write,
		.Set_Millimetres,
		"G21\n",
	) ||
	   !marlin_write_literal(
		&builder,
		commands,
		&command_write,
		.Set_Absolute_Coordinates,
		"G90\n",
	) ||
	   !marlin_write_literal(
		&builder,
		commands,
		&command_write,
		.Set_Relative_Extrusion,
		"M83\n",
	) ||
	   !marlin_write_literal(
		&builder,
		commands,
		&command_write,
		.Set_Fan,
		"M107\n",
	) {
		delete(commands, allocator)
		return {}, .Command_Limit
	}
	state.fan_pwm = 0
	bed_temperature := i32(profile.process.source.bed_temperature)
	if bed_temperature > 0 {
		start := marlin_command_begin(builder)
		fmt.sbprintf(&builder, "M140 S%d\n", bed_temperature)
		if !marlin_command_end(
			builder,
			commands,
			&command_write,
			.Set_Bed_Temperature,
			start,
		) {
			delete(commands, allocator)
			return {}, .Command_Limit
		}
	}
	if !marlin_write_literal(
		&builder,
		commands,
		&command_write,
		.Home_All_Axes,
		"G28\n",
	) {
		delete(commands, allocator)
		return {}, .Command_Limit
	}
	if bed_temperature > 0 {
		start := marlin_command_begin(builder)
		fmt.sbprintf(&builder, "M190 S%d\n", bed_temperature)
		if !marlin_command_end(
			builder,
			commands,
			&command_write,
			.Wait_Bed_Temperature,
			start,
		) {
			delete(commands, allocator)
			return {}, .Command_Limit
		}
	}
	switch profile.printer.bed_leveling {
	case .None:
	case .Probe_Before_Print:
		if !marlin_write_literal(
			&builder,
			commands,
			&command_write,
			.Probe_Bed,
			"G29\n",
		) {
			delete(commands, allocator)
			return {}, .Command_Limit
		}
	case .Restore_Stored_Mesh:
		if !marlin_write_literal(
			&builder,
			commands,
			&command_write,
			.Restore_Bed_Mesh,
			"M420 S1\n",
		) {
			delete(commands, allocator)
			return {}, .Command_Limit
		}
	case .Invalid:
		delete(commands, allocator)
		return {}, .Invalid_Profile
	}
	start := marlin_command_begin(builder)
	fmt.sbprintf(
		&builder,
		"M109 S%d\n",
		i32(profile.process.source.nozzle_temperature),
	)
	if !marlin_command_end(
		builder,
		commands,
		&command_write,
		.Wait_Nozzle_Temperature,
		start,
	) {
		delete(commands, allocator)
		return {}, .Command_Limit
	}

	for layer in motion.layers {
		start = marlin_command_begin(builder)
		fmt.sbprintf(&builder, ";LAYER:%d Z:", layer.layer_index)
		marlin_append_coordinate(&builder, layer.z)
		strings.write_string(&builder, "\n")
		if !marlin_command_end(
			builder,
			commands,
			&command_write,
			.Comment,
			start,
			layer_index = layer.layer_index,
		) {
			delete(commands, allocator)
			return {}, .Command_Limit
		}
		if !marlin_emit_acceleration(
			&builder,
			commands,
			&command_write,
			&state,
			.Travel,
			profile.process.source.travel.acceleration,
			{},
			layer.layer_index,
		) {
			delete(commands, allocator)
			return {}, .Command_Limit
		}
		start = marlin_command_begin(builder)
		strings.write_string(&builder, "G0 Z")
		marlin_append_coordinate(&builder, layer.z)
		fmt.sbprintf(
			&builder,
			" F%d\n",
			marlin_feed_rate(profile.process.source.travel.speed),
		)
		if !marlin_command_end(
			builder,
			commands,
			&command_write,
			.Move,
			start,
			layer_index = layer.layer_index,
		) {
			delete(commands, allocator)
			return {}, .Command_Limit
		}
		state.z = layer.z

		operation_start := int(layer.operation_offset)
		operation_end :=
			operation_start+int(layer.operation_count)
		for operation in motion.operations[operation_start:operation_end] {
			if !state.positioned_xy && operation.kind != .Dwell {
				start = marlin_command_begin(builder)
				strings.write_string(&builder, "G0 X")
				marlin_append_coordinate(&builder, operation.point_a.x)
				strings.write_string(&builder, " Y")
				marlin_append_coordinate(&builder, operation.point_a.y)
				fmt.sbprintf(
					&builder,
					" F%d\n",
					marlin_feed_rate(
						profile.process.source.travel.speed,
					),
				)
				if !marlin_command_end(
					builder,
					commands,
					&command_write,
					.Move,
					start,
					layer_index = layer.layer_index,
				) {
					delete(commands, allocator)
					return {}, .Command_Limit
				}
				state.positioned_xy = true
				state.x = operation.point_a.x
				state.y = operation.point_a.y
			}
			if !marlin_emit_operation(
				&builder,
				commands,
				&command_write,
				&state,
				operation,
				&result,
			) {
				delete(commands, allocator)
				return {}, .Command_Limit
			}
		}
	}

	if profile.printer.park_after_print && result.positive_filament_nm > 0 {
		if len(motion.layers) == 0 {
			delete(commands, allocator)
			return {}, .Invalid_Motion
		}
		lifted_z :=
			i64(state.z)+i64(profile.printer.park_z_lift)
		if lifted_z > i64(profile.printer.axis_maximum_z) {
			delete(commands, allocator)
			return {}, .Invalid_Motion
		}
		if !marlin_emit_acceleration(
			&builder,
			commands,
			&command_write,
			&state,
			.Retract,
			profile.process.source.retraction_acceleration,
			{},
			max(u32),
		) {
			delete(commands, allocator)
			return {}, .Command_Limit
		}
		shutdown_retraction_nm :=
			u64(i64(profile.process.source.retraction_distance))*1_000
		start = marlin_command_begin(builder)
		strings.write_string(&builder, "G1 E")
		marlin_append_extrusion(&builder, -i128(shutdown_retraction_nm))
		fmt.sbprintf(
			&builder,
			" F%d\n",
			marlin_feed_rate(profile.process.source.retraction_speed),
		)
		if !marlin_command_end(
			builder,
			commands,
			&command_write,
			.Move,
			start,
		) {
			delete(commands, allocator)
			return {}, .Command_Limit
		}
		result.shutdown_retraction_nm = shutdown_retraction_nm
		result.negative_filament_nm += u128(shutdown_retraction_nm)
		if !marlin_emit_acceleration(
			&builder,
			commands,
			&command_write,
			&state,
			.Travel,
			profile.process.source.travel.acceleration,
			{},
			max(u32),
		) {
			delete(commands, allocator)
			return {}, .Command_Limit
		}
		start = marlin_command_begin(builder)
		strings.write_string(&builder, "G0 Z")
		marlin_append_coordinate(
			&builder,
			contracts.Micrometres(lifted_z),
		)
		fmt.sbprintf(
			&builder,
			" F%d\n",
			marlin_feed_rate(profile.process.source.travel.speed),
		)
		if !marlin_command_end(
			builder,
			commands,
			&command_write,
			.Move,
			start,
		) {
			delete(commands, allocator)
			return {}, .Command_Limit
		}
		state.z = contracts.Micrometres(lifted_z)
		start = marlin_command_begin(builder)
		strings.write_string(&builder, "G0 X")
		marlin_append_coordinate(&builder, profile.printer.park_x)
		strings.write_string(&builder, " Y")
		marlin_append_coordinate(&builder, profile.printer.park_y)
		fmt.sbprintf(
			&builder,
			" F%d\n",
			marlin_feed_rate(profile.process.source.travel.speed),
		)
		if !marlin_command_end(
			builder,
			commands,
			&command_write,
			.Move,
			start,
		) {
			delete(commands, allocator)
			return {}, .Command_Limit
		}
		state.x = profile.printer.park_x
		state.y = profile.printer.park_y
	}

	if !marlin_write_literal(
		&builder,
		commands,
		&command_write,
		.Set_Fan,
		"M107\n",
	) ||
	   !marlin_write_literal(
		&builder,
		commands,
		&command_write,
		.Set_Nozzle_Temperature,
		"M104 S0\n",
	) ||
	   !marlin_write_literal(
		&builder,
		commands,
		&command_write,
		.Set_Bed_Temperature,
		"M140 S0\n",
	) ||
	   !marlin_write_literal(
		&builder,
		commands,
		&command_write,
		.Disable_Steppers,
		"M84\n",
	) {
		delete(commands, allocator)
		return {}, .Command_Limit
	}
	text := strings.to_string(builder)
	if u64(len(text)) > limits.max_bytes {
		delete(commands, allocator)
		return {}, .Byte_Limit
	}
	result.bytes = make([]u8, len(text), allocator)
	if len(text) > 0 && result.bytes == nil {
		delete(commands, allocator)
		return {}, .Allocation_Failed
	}
	copy(result.bytes, transmute([]u8)text)
	result.commands = commands[:command_write]
	result.final_x = state.x
	result.final_y = state.y
	result.final_z = state.z
	report, validation_error :=
		marlin_validate(result.bytes, profile, motion)
	if validation_error != .None ||
	   report.command_count != u64(len(result.commands)) ||
	   report.positive_filament_nm != result.positive_filament_nm ||
	   report.negative_filament_nm != result.negative_filament_nm ||
	   report.dwell_ms != result.emitted_dwell_ms ||
	   report.final_x != result.final_x ||
	   report.final_y != result.final_y ||
	   report.final_z != result.final_z {
		marlin_result_destroy(&result, allocator)
		return {}, .Invalid_Motion
	}
	return result, .None
}

marlin_emit_operation :: proc(
	builder: ^strings.Builder,
	commands: []Marlin_Command_Record,
	command_write: ^int,
	state: ^Marlin_State,
	operation: features.Motion_Operation,
	result: ^Marlin_Result,
) -> bool {
	acceleration_kind := operation.kind
	if !marlin_emit_acceleration(
		builder,
		commands,
		command_write,
		state,
		acceleration_kind,
		operation.acceleration,
		operation.stable_id,
		operation.layer_index,
	) {
		return false
	}
	if operation.kind == .Extrude {
		pwm := marlin_fan_pwm(operation.fan_ratio)
		if pwm != state.fan_pwm {
			start := marlin_command_begin(builder^)
			if pwm == 0 {
				strings.write_string(builder, "M107\n")
			} else {
				fmt.sbprintf(builder, "M106 S%d\n", pwm)
			}
			if !marlin_command_end(
				builder^,
				commands,
				command_write,
				.Set_Fan,
				start,
				operation.stable_id,
				operation.layer_index,
			) {
				return false
			}
			state.fan_pwm = pwm
		}
	}
	start := marlin_command_begin(builder^)
	switch operation.kind {
	case .Retract, .Recover:
		strings.write_string(builder, "G1 E")
		marlin_append_extrusion(builder, operation.filament_delta_nm)
		fmt.sbprintf(
			builder,
			" F%d\n",
			marlin_feed_rate(operation.speed),
		)
	case .Travel:
		strings.write_string(builder, "G0 X")
		marlin_append_coordinate(builder, operation.point_b.x)
		strings.write_string(builder, " Y")
		marlin_append_coordinate(builder, operation.point_b.y)
		fmt.sbprintf(
			builder,
			" F%d\n",
			marlin_feed_rate(operation.speed),
		)
	case .Extrude:
		strings.write_string(builder, "G1 X")
		marlin_append_coordinate(builder, operation.point_b.x)
		strings.write_string(builder, " Y")
		marlin_append_coordinate(builder, operation.point_b.y)
		strings.write_string(builder, " E")
		marlin_append_extrusion(builder, operation.filament_delta_nm)
		fmt.sbprintf(
			builder,
			" F%d\n",
			marlin_feed_rate(operation.speed),
		)
	case .Dwell:
		dwell_ms := (operation.duration_us+999)/1_000
		fmt.sbprintf(builder, "G4 P%d\n", dwell_ms)
		result.emitted_dwell_ms += dwell_ms
	case .Invalid:
		return false
	}
	if !marlin_command_end(
		builder^,
		commands,
		command_write,
		.Dwell if operation.kind == .Dwell else .Move,
		start,
		operation.stable_id,
		operation.layer_index,
	) {
		return false
	}
	if operation.filament_delta_nm > 0 {
		result.positive_filament_nm +=
			u128(operation.filament_delta_nm)
	} else if operation.filament_delta_nm < 0 {
		result.negative_filament_nm +=
			u128(-operation.filament_delta_nm)
	}
	if operation.kind == .Travel || operation.kind == .Extrude {
		state.positioned_xy = true
		state.x = operation.point_b.x
		state.y = operation.point_b.y
	}
	return true
}

marlin_emit_acceleration :: proc(
	builder: ^strings.Builder,
	commands: []Marlin_Command_Record,
	command_write: ^int,
	state: ^Marlin_State,
	operation_kind: features.Motion_Operation_Kind,
	acceleration: profiles.Acceleration_Um_Per_Second_Squared,
	source_operation_id: contracts.Stable_ID,
	layer_index: u32,
) -> bool {
	if operation_kind == .Dwell {return true}
	value := i64(acceleration)/1_000
	kind: Marlin_Command_Kind
	prefix := ""
	current: ^i64
	switch operation_kind {
	case .Extrude:
		kind = .Set_Print_Acceleration
		prefix = "M204 P"
		current = &state.print_acceleration
	case .Travel:
		kind = .Set_Travel_Acceleration
		prefix = "M204 T"
		current = &state.travel_acceleration
	case .Retract, .Recover:
		kind = .Set_Retract_Acceleration
		prefix = "M204 R"
		current = &state.retract_acceleration
	case .Dwell:
		return true
	case .Invalid:
		return false
	}
	if current^ == value {return true}
	start := marlin_command_begin(builder^)
	fmt.sbprintf(builder, "%s%d\n", prefix, value)
	if !marlin_command_end(
		builder^,
		commands,
		command_write,
		kind,
		start,
		source_operation_id,
		layer_index,
	) {
		return false
	}
	current^ = value
	return true
}

marlin_motion_valid :: proc(
	motion: features.Motion_Plan_Result,
	profile: profiles.Resolved_Profiles,
) -> bool {
	if len(motion.layers) == 0 || motion.extrusion_count == 0 {
		return false
	}
	expected_offset: u64
	retraction_count: u64
	travel_count: u64
	extrusion_count: u64
	dwell_count: u64
	total_motion: u64
	total_dwell: u64
	total_planned: u64
	previous_z := i64(profile.printer.axis_minimum_z)
	for layer, layer_index in motion.layers {
		layer_z := i64(layer.z)
		operation_limit :=
			layer.operation_offset+u64(layer.operation_count)
		duration_sum, duration_ok := marlin_checked_add_u64(
			layer.motion_duration_us,
			layer.dwell_duration_us,
		)
		if layer.stable_id == contracts.INVALID_STABLE_ID ||
		   layer.layer_index != u32(layer_index) ||
		   layer.operation_offset != expected_offset ||
		   operation_limit > u64(len(motion.operations)) ||
		   layer_z <= previous_z ||
		   layer_z > i64(profile.printer.axis_maximum_z) ||
		   layer.speed_scale_ppm > profiles.RATIO_SCALE ||
		   !duration_ok ||
		   layer.planned_duration_us != duration_sum {
			return false
		}
		previous_z = layer_z
		operation_start := int(layer.operation_offset)
		operation_end := operation_start+int(layer.operation_count)
		layer_motion: u64
		layer_dwell: u64
		for operation in motion.operations[operation_start:operation_end] {
			if operation.stable_id == contracts.INVALID_STABLE_ID ||
			   operation.layer_index != u32(layer_index) ||
			   operation.duration_us == 0 ||
			   !marlin_operation_numeric_valid(operation, profile) {
				return false
			}
			if operation.kind == .Dwell {
				layer_dwell, duration_ok = marlin_checked_add_u64(
					layer_dwell,
					operation.duration_us,
				)
				dwell_count += 1
			} else {
				layer_motion, duration_ok = marlin_checked_add_u64(
					layer_motion,
					operation.duration_us,
				)
			}
			if !duration_ok {return false}
			switch operation.kind {
			case .Retract:
				if operation.filament_delta_nm >= 0 {
					return false
				}
				retraction_count += 1
			case .Travel:
				if operation.filament_delta_nm != 0 ||
				   operation.role != .Invalid ||
				   operation.point_a == operation.point_b {
					return false
				}
				travel_count += 1
			case .Recover:
				if operation.filament_delta_nm <= 0 {
					return false
				}
			case .Extrude:
				if operation.filament_delta_nm <= 0 ||
				   operation.role == .Invalid ||
				   operation.point_a == operation.point_b {
					return false
				}
				extrusion_count += 1
			case .Dwell:
				if operation.filament_delta_nm != 0 ||
				   operation.speed != 0 ||
				   operation.acceleration != 0 ||
				   operation.point_a != operation.point_b {
					return false
				}
			case .Invalid:
				return false
			}
		}
		if layer.motion_duration_us != layer_motion ||
		   layer.dwell_duration_us != layer_dwell {
			return false
		}
		total_motion, duration_ok =
			marlin_checked_add_u64(total_motion, layer_motion)
		if duration_ok {
			total_dwell, duration_ok =
				marlin_checked_add_u64(total_dwell, layer_dwell)
		}
		if duration_ok {
			total_planned, duration_ok =
				marlin_checked_add_u64(
					total_planned,
					layer.planned_duration_us,
				)
		}
		if !duration_ok {return false}
		expected_offset += u64(layer.operation_count)
	}
	return expected_offset == u64(len(motion.operations)) &&
		retraction_count == motion.retraction_count &&
		travel_count == motion.travel_count &&
		extrusion_count == motion.extrusion_count &&
		dwell_count == motion.dwell_count &&
		total_motion == motion.total_motion_duration_us &&
		total_dwell == motion.total_dwell_duration_us &&
		total_planned == motion.total_planned_duration_us
}

marlin_operation_numeric_valid :: proc(
	operation: features.Motion_Operation,
	profile: profiles.Resolved_Profiles,
) -> bool {
	if operation.filament_delta_nm%10 != 0 {
		return false
	}
	if operation.kind != .Dwell &&
	   (i64(operation.speed) <= 0 ||
	    i64(operation.speed)%50 != 0 ||
	    i64(operation.acceleration) <= 0 ||
	    i64(operation.acceleration)%1_000 != 0) {
		return false
	}
	if i64(operation.point_a.x) < i64(profile.printer.axis_minimum_x) ||
	   i64(operation.point_a.x) > i64(profile.printer.axis_maximum_x) ||
	   i64(operation.point_a.y) < i64(profile.printer.axis_minimum_y) ||
	   i64(operation.point_a.y) > i64(profile.printer.axis_maximum_y) ||
	   i64(operation.point_b.x) < i64(profile.printer.axis_minimum_x) ||
	   i64(operation.point_b.x) > i64(profile.printer.axis_maximum_x) ||
	   i64(operation.point_b.y) < i64(profile.printer.axis_minimum_y) ||
	   i64(operation.point_b.y) > i64(profile.printer.axis_maximum_y) ||
	   u32(operation.fan_ratio) > profiles.RATIO_SCALE {
		return false
	}
	process := profile.process.source
	switch operation.kind {
	case .Retract:
		return operation.speed == process.retraction_speed &&
			operation.acceleration == process.retraction_acceleration &&
			operation.filament_delta_nm ==
				-i128(i64(process.retraction_distance))*1_000
	case .Recover:
		return operation.speed == process.recovery_speed &&
			operation.acceleration == process.retraction_acceleration &&
			operation.filament_delta_nm ==
				i128(i64(process.retraction_distance))*1_000
	case .Travel:
		return operation.speed == process.travel.speed &&
			operation.acceleration == process.travel.acceleration
	case .Extrude:
		target, target_ok :=
			features.motion_role_target(profile.process, operation.role)
		return target_ok &&
			i64(operation.speed) >= i64(process.minimum_print_speed) &&
			i64(operation.speed) <= i64(target.speed) &&
			operation.acceleration == target.acceleration &&
			operation.fan_ratio == target.fan_ratio
	case .Dwell:
		return true
	case .Invalid:
		return false
	}
	return false
}

marlin_write_literal :: proc(
	builder: ^strings.Builder,
	commands: []Marlin_Command_Record,
	command_write: ^int,
	kind: Marlin_Command_Kind,
	line: string,
	source_operation_id := contracts.INVALID_STABLE_ID,
	layer_index := max(u32),
) -> bool {
	start := marlin_command_begin(builder^)
	strings.write_string(builder, line)
	return marlin_command_end(
		builder^,
		commands,
		command_write,
		kind,
		start,
		source_operation_id,
		layer_index,
	)
}

marlin_command_begin :: proc(builder: strings.Builder) -> int {
	return len(strings.to_string(builder))
}

marlin_command_end :: proc(
	builder: strings.Builder,
	commands: []Marlin_Command_Record,
	command_write: ^int,
	kind: Marlin_Command_Kind,
	start: int,
	source_operation_id := contracts.INVALID_STABLE_ID,
	layer_index := max(u32),
) -> bool {
	if command_write^ >= len(commands) {return false}
	end := len(strings.to_string(builder))
	if end <= start || end-start > int(max(u32)) {
		return false
	}
	command_index := command_write^
	parent := source_operation_id
	if parent == contracts.INVALID_STABLE_ID {
		parent = contracts.Stable_ID(1)
	}
	commands[command_index] = {
		stable_id = contracts.stable_id_child(
			parent,
			.Command,
			u64(command_index),
		),
		command_index = u32(command_index),
		kind = kind,
		byte_offset = u64(start),
		byte_count = u32(end-start),
		source_operation_id = source_operation_id,
		layer_index = layer_index,
	}
	command_write^ += 1
	return true
}

marlin_append_coordinate :: proc(
	builder: ^strings.Builder,
	value: contracts.Micrometres,
) {
	marlin_append_fixed(builder, i128(value), 3)
}

marlin_append_extrusion :: proc(builder: ^strings.Builder, value_nm: i128) {
	marlin_append_fixed(builder, value_nm/10, 5)
}

marlin_append_fixed :: proc(
	builder: ^strings.Builder,
	units: i128,
	decimal_places: u8,
) {
	negative := units < 0
	magnitude := units
	if negative {magnitude = -magnitude}
	scale: i128
	switch decimal_places {
	case 3: scale = 1_000
	case 5: scale = 100_000
	case:
		return
	}
	whole := magnitude/scale
	fraction := magnitude%scale
	if negative {strings.write_string(builder, "-")}
	if decimal_places == 3 {
		fmt.sbprintf(builder, "%d.%03d", whole, fraction)
	} else {
		fmt.sbprintf(builder, "%d.%05d", whole, fraction)
	}
}

marlin_feed_rate :: proc(speed: profiles.Speed_Um_Per_Second) -> i64 {
	return i64(speed)*60/1_000
}

marlin_fan_pwm :: proc(ratio: profiles.Ratio_Ppm) -> i32 {
	return i32(
		(u64(u32(ratio))*255+u64(profiles.RATIO_SCALE/2))/
		u64(profiles.RATIO_SCALE),
	)
}

marlin_checked_add_u64 :: proc(a, b: u64) -> (u64, bool) {
	if b > max(u64)-a {return 0, false}
	return a+b, true
}

marlin_result_destroy :: proc(
	result: ^Marlin_Result,
	allocator := context.allocator,
) {
	delete(result.bytes, allocator)
	delete(result.commands, allocator)
	result^ = {}
}
