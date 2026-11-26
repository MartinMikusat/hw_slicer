package gcode

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"

import contracts "../contracts"
import features "../features"
import polygon "../polygon"
import profiles "../profiles"
import workers "../workers"

@(private)
g_gcode_worker_threads := 1

set_worker_threads :: proc(n: int) {
	g_gcode_worker_threads = clamp(n, 1, workers.MAX_WORKERS)
}

KLIPPER_EMITTER_SCHEMA_VERSION :: u32(3)
KLIPPER_HEADER :: "; hw_slicer klipper"

// The printer's START_PRINT and END_PRINT macros own homing, heating, bed meshing, priming,
// parking and shutdown. START_PRINT takes the RatOS parameters: temperatures and the
// extrusion area X0, Y0, X1, Y1 in mm.
Klipper_Command_Kind :: enum u8 {
	Invalid,
	Comment,
	Set_Print_Stats,
	Start_Print,
	Set_Millimetres,
	Set_Absolute_Coordinates,
	Set_Relative_Extrusion,
	Set_Acceleration,
	Set_Fan,
	Move,
	Dwell,
	Exclude_Object,
	Pause_Or_Filament,
	End_Print,
}

Klipper_Command_Record :: struct {
	stable_id:          contracts.Stable_ID,
	command_index:      u32,
	kind:               Klipper_Command_Kind,
	byte_offset:        u64,
	byte_count:         u32,
	source_operation_id: contracts.Stable_ID,
	layer_index:        u32,
}

Klipper_Result :: struct {
	schema_version:             u32,
	bytes:                      []u8,
	commands:                   []Klipper_Command_Record,
	layer_count:                u32,
	motion_operation_count:     u64,
	positive_filament_nm:       u128,
	negative_filament_nm:       u128,
	emitted_dwell_ms:           u64,
	final_x:                    contracts.Micrometres,
	final_y:                    contracts.Micrometres,
	final_z:                    contracts.Micrometres,
	validation:                 Klipper_Validation_Report,
	plan_cuts:                  []Klipper_Plan_Cut,
}

Klipper_Plan_Cut :: struct {
	byte_offset:  u64,
	x:            contracts.Micrometres,
	y:            contracts.Micrometres,
	z:            contracts.Micrometres,
	feed:         i64,
	acceleration: i64,
}

Klipper_Limits :: struct {
	max_commands: u64,
	max_bytes:    u64,
}

DEFAULT_KLIPPER_LIMITS :: Klipper_Limits{
	max_commands = 20_000_000_000,
	max_bytes = 16*1024*1024*1024,
}

Klipper_Error :: enum u8 {
	None,
	Invalid_Profile,
	Invalid_Motion,
	Command_Limit,
	Byte_Limit,
	Allocation_Failed,
	Arithmetic,
}

Klipper_State :: struct {
	acceleration:         i64, // mm/s²; -1 until set
	feed:                 i64, // mm/min; -1 until set
	fan_pwm:              i32,
	positioned_xy:        bool,
	x:                    contracts.Micrometres,
	y:                    contracts.Micrometres,
	z:                    contracts.Micrometres,
	physical_z:           contracts.Micrometres,
}

klipper_emit :: proc(
	motion: features.Motion_Plan_Result,
	profile: profiles.Resolved_Profiles,
	limits := DEFAULT_KLIPPER_LIMITS,
	allocator := context.allocator,
	object_name := "",
	pause_layers: []u32 = nil,
	color_change_layers: []u32 = nil,
	record_commands := true,
	minimum_cruise_ratio_ppm: i64 = -1,
) -> (Klipper_Result, Klipper_Error) {
	if minimum_cruise_ratio_ppm < -1 || minimum_cruise_ratio_ppm >= i64(profiles.RATIO_SCALE) {
		return {}, .Invalid_Profile
	}
	resolved, resolve_error := profiles.profiles_resolve(
		profile.printer,
		profile.material,
		profile.process.source,
		profile.dialect,
	)
	if resolve_error != .None || resolved != profile {
		return {}, .Invalid_Profile
	}
	if !klipper_motion_valid(motion, profile, record_commands) {
		return {}, .Invalid_Motion
	}
	if g_gcode_worker_threads > 1 && len(motion.layers) >= 4 {
		return klipper_emit_parallel(
			motion,
			profile,
			limits,
			allocator,
			object_name,
			pause_layers,
			color_change_layers,
			record_commands,
			minimum_cruise_ratio_ppm,
		)
	}
	object_name := klipper_object_name(object_name, context.temp_allocator) if len(object_name) > 0 else ""
	maximum_commands :=
		u64(36)+u64(len(motion.layers))*5+
		u64(len(motion.operations))*5
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
	commands: []Klipper_Command_Record
	if record_commands {
		commands = make([]Klipper_Command_Record, int(maximum_commands), allocator)
		if maximum_commands > 0 && commands == nil {
			return {}, .Allocation_Failed
		}
	}
	command_write := 0
	result := Klipper_Result{
		schema_version = KLIPPER_EMITTER_SCHEMA_VERSION,
		layer_count = u32(len(motion.layers)),
		motion_operation_count = u64(len(motion.operations)),
	}
	state := Klipper_State{
		acceleration = -1,
		feed         = -1,
		fan_pwm      = -1,
	}
	plan_cuts := make([dynamic]Klipper_Plan_Cut, 0, len(motion.layers), allocator)
	plan_cuts_owned := false
	defer if !plan_cuts_owned {delete(plan_cuts)}

	area := klipper_extrusion_area(motion)
	start := klipper_command_begin(builder)
	fmt.sbprintf(&builder, "%s\n", KLIPPER_HEADER)
	if !klipper_command_end(builder, commands, &command_write, .Comment, start) {
		delete(commands, allocator)
		return {}, .Command_Limit
	}
	start = klipper_command_begin(builder)
	fmt.sbprintf(&builder, "SET_PRINT_STATS_INFO TOTAL_LAYER=%d\n", len(motion.layers))
	if !klipper_command_end(builder, commands, &command_write, .Set_Print_Stats, start) {
		delete(commands, allocator)
		return {}, .Command_Limit
	}
	nozzle_temperature := i32(profile.process.source.nozzle_temperature)
	start = klipper_command_begin(builder)
	fmt.sbprintf(
		&builder,
		"START_PRINT EXTRUDER_TEMP=%d EXTRUDER_OTHER_LAYER_TEMP=%d BED_TEMP=%d X0=",
		nozzle_temperature,
		nozzle_temperature,
		i32(profile.process.source.bed_temperature),
	)
	klipper_append_coordinate(&builder, area[0].x)
	strings.write_string(&builder, " Y0=")
	klipper_append_coordinate(&builder, area[0].y)
	strings.write_string(&builder, " X1=")
	klipper_append_coordinate(&builder, area[1].x)
	strings.write_string(&builder, " Y1=")
	klipper_append_coordinate(&builder, area[1].y)
	strings.write_string(&builder, "\n")
	if !klipper_command_end(builder, commands, &command_write, .Start_Print, start) ||
	   !klipper_write_literal(&builder, commands, &command_write, .Set_Millimetres, "G21\n") ||
	   !klipper_write_literal(&builder, commands, &command_write, .Set_Absolute_Coordinates, "G90\n") ||
	   !klipper_write_literal(&builder, commands, &command_write, .Set_Relative_Extrusion, "M83\n") ||
	   !klipper_write_literal(&builder, commands, &command_write, .Set_Fan, "M107\n") ||
	   !klipper_write_cruise_ratio(&builder, commands, &command_write, minimum_cruise_ratio_ppm) {
		delete(commands, allocator)
		return {}, .Command_Limit
	}
	state.fan_pwm = 0

	if len(object_name) > 0 {
		cx := contracts.Micrometres((i64(area[0].x) + i64(area[1].x)) / 2)
		cy := contracts.Micrometres((i64(area[0].y) + i64(area[1].y)) / 2)
		start = klipper_command_begin(builder)
		fmt.sbprintf(&builder, "EXCLUDE_OBJECT_DEFINE NAME=%s CENTER=", object_name)
		klipper_append_coordinate(&builder, cx)
		strings.write_string(&builder, ",")
		klipper_append_coordinate(&builder, cy)
		strings.write_string(&builder, " POLYGON=[[")
		klipper_append_coordinate(&builder, area[0].x)
		strings.write_string(&builder, ",")
		klipper_append_coordinate(&builder, area[0].y)
		strings.write_string(&builder, "],[")
		klipper_append_coordinate(&builder, area[1].x)
		strings.write_string(&builder, ",")
		klipper_append_coordinate(&builder, area[0].y)
		strings.write_string(&builder, "],[")
		klipper_append_coordinate(&builder, area[1].x)
		strings.write_string(&builder, ",")
		klipper_append_coordinate(&builder, area[1].y)
		strings.write_string(&builder, "],[")
		klipper_append_coordinate(&builder, area[0].x)
		strings.write_string(&builder, ",")
		klipper_append_coordinate(&builder, area[1].y)
		strings.write_string(&builder, "]]\n")
		if !klipper_command_end(builder, commands, &command_write, .Exclude_Object, start) {
			delete(commands, allocator)
			return {}, .Command_Limit
		}
		start = klipper_command_begin(builder)
		fmt.sbprintf(&builder, "EXCLUDE_OBJECT_START NAME=%s\n", object_name)
		if !klipper_command_end(builder, commands, &command_write, .Exclude_Object, start) {
			delete(commands, allocator)
			return {}, .Command_Limit
		}
	}

	for layer in motion.layers {
		start = klipper_command_begin(builder)
		fmt.sbprintf(&builder, ";LAYER:%d Z:", layer.layer_index)
		klipper_append_coordinate(&builder, layer.z)
		strings.write_string(&builder, "\n")
		if !klipper_command_end(
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
		start = klipper_command_begin(builder)
		fmt.sbprintf(&builder, "SET_PRINT_STATS_INFO CURRENT_LAYER=%d\n", layer.layer_index+1)
		if !klipper_command_end(
			builder,
			commands,
			&command_write,
			.Set_Print_Stats,
			start,
			layer_index = layer.layer_index,
		) {
			delete(commands, allocator)
			return {}, .Command_Limit
		}
		if !klipper_emit_acceleration(
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
		layer_start_z := klipper_layer_start_z(motion, layer)
		start = klipper_command_begin(builder)
		strings.write_string(&builder, "G0 Z")
		klipper_append_coordinate(&builder, layer_start_z)
		klipper_append_feed(&builder, &state, klipper_feed_rate(profile.process.source.travel.speed))
		if !klipper_command_end(
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
		state.physical_z = layer_start_z

		for pl in pause_layers {
			if pl == layer.layer_index {
				if !klipper_write_literal(&builder, commands, &command_write, .Pause_Or_Filament, "PAUSE\n", {}, layer.layer_index) {
					delete(commands, allocator)
					return {}, .Command_Limit
				}
				state.feed = -1
				break
			}
		}
		for cl in color_change_layers {
			if cl == layer.layer_index {
				if !klipper_write_literal(&builder, commands, &command_write, .Pause_Or_Filament, "M600\n", {}, layer.layer_index) {
					delete(commands, allocator)
					return {}, .Command_Limit
				}
				state.feed = -1
				break
			}
		}

		operation_start := int(layer.operation_offset)
		operation_end :=
			operation_start+int(layer.operation_count)
		layer_cut := false
		for operation in motion.operations[operation_start:operation_end] {
			if !state.positioned_xy && operation.kind != .Dwell {
				start = klipper_command_begin(builder)
				strings.write_string(&builder, "G0 X")
				klipper_append_coordinate(&builder, operation.point_a.x)
				strings.write_string(&builder, " Y")
				klipper_append_coordinate(&builder, operation.point_a.y)
				klipper_append_feed(&builder, &state, klipper_feed_rate(profile.process.source.travel.speed))
				if !klipper_command_end(
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
			if !layer_cut && klipper_plan_cut_operation(operation.kind) && state.feed >= 0 {
				append(&plan_cuts, klipper_plan_cut(state, u64(len(builder.buf))))
				layer_cut = true
			}
			if !klipper_emit_operation(
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

	if len(object_name) > 0 {
		start = klipper_command_begin(builder)
		fmt.sbprintf(&builder, "EXCLUDE_OBJECT_END NAME=%s\n", object_name)
		if !klipper_command_end(builder, commands, &command_write, .Exclude_Object, start) {
			delete(commands, allocator)
			return {}, .Command_Limit
		}
	}

	if !klipper_write_cruise_ratio_restore(&builder, commands, &command_write, profile, minimum_cruise_ratio_ppm) ||
	   !klipper_write_literal(&builder, commands, &command_write, .End_Print, "END_PRINT\n") {
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
	result.commands = commands[:command_write] if record_commands else nil
	result.plan_cuts = plan_cuts[:]
	plan_cuts_owned = true
	result.final_x = state.x
	result.final_y = state.y
	result.final_z = state.z
	report, validation_error :=
		klipper_validate(result.bytes, profile, motion, record_commands)
	if validation_error != .None ||
	   !klipper_cruise_ratio_reported(report, minimum_cruise_ratio_ppm) ||
	   report.minimum_cruise_ratio_restored != (minimum_cruise_ratio_ppm >= 0) ||
	   report.command_count != u64(command_write) ||
	   report.positive_filament_nm != result.positive_filament_nm ||
	   report.negative_filament_nm != result.negative_filament_nm ||
	   report.dwell_ms != result.emitted_dwell_ms ||
	   report.final_x != result.final_x ||
	   report.final_y != result.final_y ||
	   report.final_z != result.final_z {
		klipper_result_destroy(&result, allocator)
		return {}, .Invalid_Motion
	}
	result.validation = report
	return result, .None
}

@(private = "file")
Klipper_Layer_Emit :: struct {
	init_state:           Klipper_State,
	end_state:            Klipper_State,
	builder:              strings.Builder,
	commands_buf:         []Klipper_Command_Record,
	command_count:        int,
	positive_filament_nm: u128,
	negative_filament_nm: u128,
	emitted_dwell_ms:     u64,
	byte_offset:          u64,
	command_offset:       u64,
	cut:                  Klipper_Plan_Cut,
	has_cut:              bool,
	ok:                   bool,
	val_end_state:        Klipper_Validation_State,
	val_report:           Klipper_Validation_Report,
	val_error:            Klipper_Validation_Error,
}

@(private = "file")
Klipper_Parallel_Context :: struct {
	motion:              features.Motion_Plan_Result,
	profile:             profiles.Resolved_Profiles,
	pause_layers:        []u32,
	color_change_layers: []u32,
	allocator:           mem.Allocator,
	layers:              []Klipper_Layer_Emit,
	out_bytes:           []u8,
	out_commands:        []Klipper_Command_Record,
	record_commands:     bool,
}

@(private = "file")
klipper_emit_parallel :: proc(
	motion: features.Motion_Plan_Result,
	profile: profiles.Resolved_Profiles,
	limits: Klipper_Limits,
	allocator := context.allocator,
	object_name := "",
	pause_layers: []u32 = nil,
	color_change_layers: []u32 = nil,
	record_commands := true,
	minimum_cruise_ratio_ppm: i64 = -1,
) -> (Klipper_Result, Klipper_Error) {
	layer_count := len(motion.layers)
	object_name_clean := klipper_object_name(object_name, context.temp_allocator) if len(object_name) > 0 else ""

	// Header (startup + optional EXCLUDE_OBJECT_DEFINE/START).
	header_builder, hdr_err := strings.builder_make(0, 1024, allocator)
	if hdr_err != nil {return {}, .Allocation_Failed}
	defer strings.builder_destroy(&header_builder)
	header_cmds := make([]Klipper_Command_Record, 16, allocator)
	if header_cmds == nil {return {}, .Allocation_Failed}
	defer delete(header_cmds, allocator)
	header_cmd_write := 0

	area := klipper_extrusion_area(motion)
	start := klipper_command_begin(header_builder)
	fmt.sbprintf(&header_builder, "%s\n", KLIPPER_HEADER)
	if !klipper_command_end(header_builder, header_cmds, &header_cmd_write, .Comment, start) {
		return {}, .Command_Limit
	}
	start = klipper_command_begin(header_builder)
	fmt.sbprintf(&header_builder, "SET_PRINT_STATS_INFO TOTAL_LAYER=%d\n", layer_count)
	if !klipper_command_end(header_builder, header_cmds, &header_cmd_write, .Set_Print_Stats, start) {
		return {}, .Command_Limit
	}
	nozzle_temperature := i32(profile.process.source.nozzle_temperature)
	start = klipper_command_begin(header_builder)
	fmt.sbprintf(
		&header_builder,
		"START_PRINT EXTRUDER_TEMP=%d EXTRUDER_OTHER_LAYER_TEMP=%d BED_TEMP=%d X0=",
		nozzle_temperature,
		nozzle_temperature,
		i32(profile.process.source.bed_temperature),
	)
	klipper_append_coordinate(&header_builder, area[0].x)
	strings.write_string(&header_builder, " Y0=")
	klipper_append_coordinate(&header_builder, area[0].y)
	strings.write_string(&header_builder, " X1=")
	klipper_append_coordinate(&header_builder, area[1].x)
	strings.write_string(&header_builder, " Y1=")
	klipper_append_coordinate(&header_builder, area[1].y)
	strings.write_string(&header_builder, "\n")
	if !klipper_command_end(header_builder, header_cmds, &header_cmd_write, .Start_Print, start) ||
	   !klipper_write_literal(&header_builder, header_cmds, &header_cmd_write, .Set_Millimetres, "G21\n") ||
	   !klipper_write_literal(&header_builder, header_cmds, &header_cmd_write, .Set_Absolute_Coordinates, "G90\n") ||
	   !klipper_write_literal(&header_builder, header_cmds, &header_cmd_write, .Set_Relative_Extrusion, "M83\n") ||
	   !klipper_write_literal(&header_builder, header_cmds, &header_cmd_write, .Set_Fan, "M107\n") ||
	   !klipper_write_cruise_ratio(&header_builder, header_cmds, &header_cmd_write, minimum_cruise_ratio_ppm) {
		return {}, .Command_Limit
	}
	if len(object_name_clean) > 0 {
		cx := contracts.Micrometres((i64(area[0].x)+i64(area[1].x))/2)
		cy := contracts.Micrometres((i64(area[0].y)+i64(area[1].y))/2)
		start = klipper_command_begin(header_builder)
		fmt.sbprintf(&header_builder, "EXCLUDE_OBJECT_DEFINE NAME=%s CENTER=", object_name_clean)
		klipper_append_coordinate(&header_builder, cx)
		strings.write_string(&header_builder, ",")
		klipper_append_coordinate(&header_builder, cy)
		strings.write_string(&header_builder, " POLYGON=[[")
		klipper_append_coordinate(&header_builder, area[0].x)
		strings.write_string(&header_builder, ",")
		klipper_append_coordinate(&header_builder, area[0].y)
		strings.write_string(&header_builder, "],[")
		klipper_append_coordinate(&header_builder, area[1].x)
		strings.write_string(&header_builder, ",")
		klipper_append_coordinate(&header_builder, area[0].y)
		strings.write_string(&header_builder, "],[")
		klipper_append_coordinate(&header_builder, area[1].x)
		strings.write_string(&header_builder, ",")
		klipper_append_coordinate(&header_builder, area[1].y)
		strings.write_string(&header_builder, "],[")
		klipper_append_coordinate(&header_builder, area[0].x)
		strings.write_string(&header_builder, ",")
		klipper_append_coordinate(&header_builder, area[1].y)
		strings.write_string(&header_builder, "]]\n")
		if !klipper_command_end(header_builder, header_cmds, &header_cmd_write, .Exclude_Object, start) {
			return {}, .Command_Limit
		}
		start = klipper_command_begin(header_builder)
		fmt.sbprintf(&header_builder, "EXCLUDE_OBJECT_START NAME=%s\n", object_name_clean)
		if !klipper_command_end(header_builder, header_cmds, &header_cmd_write, .Exclude_Object, start) {
			return {}, .Command_Limit
		}
	}

	// Footer (optional EXCLUDE_OBJECT_END + END_PRINT).
	footer_builder, ftr_err := strings.builder_make(0, 128, allocator)
	if ftr_err != nil {return {}, .Allocation_Failed}
	defer strings.builder_destroy(&footer_builder)
	footer_cmds := make([]Klipper_Command_Record, 4, allocator)
	if footer_cmds == nil {return {}, .Allocation_Failed}
	defer delete(footer_cmds, allocator)
	footer_cmd_write := 0
	if len(object_name_clean) > 0 {
		start = klipper_command_begin(footer_builder)
		fmt.sbprintf(&footer_builder, "EXCLUDE_OBJECT_END NAME=%s\n", object_name_clean)
		if !klipper_command_end(footer_builder, footer_cmds, &footer_cmd_write, .Exclude_Object, start) {
			return {}, .Command_Limit
		}
	}
	if !klipper_write_cruise_ratio_restore(&footer_builder, footer_cmds, &footer_cmd_write, profile, minimum_cruise_ratio_ppm) ||
	   !klipper_write_literal(&footer_builder, footer_cmds, &footer_cmd_write, .End_Print, "END_PRINT\n") {
		return {}, .Command_Limit
	}

	worker_allocator := runtime.heap_allocator()
	layer_emits := make([]Klipper_Layer_Emit, layer_count, allocator)
	if layer_emits == nil {return {}, .Allocation_Failed}
	defer {
		for &le in layer_emits {
			strings.builder_destroy(&le.builder)
			delete(le.commands_buf, worker_allocator)
		}
		delete(layer_emits, allocator)
	}
	cur_state := Klipper_State{
		acceleration = -1,
		feed         = -1,
		fan_pwm      = 0,
	}
	travel_accel := i64(profile.process.source.travel.acceleration)/1_000
	travel_feed := klipper_feed_rate(profile.process.source.travel.speed)
	for layer, li in motion.layers {
		layer_emits[li].init_state = cur_state
		op_start := int(layer.operation_offset)
		op_end := op_start+int(layer.operation_count)
		cur_state.acceleration = travel_accel
		cur_state.feed = travel_feed
		for pl in pause_layers {
			if pl == layer.layer_index {cur_state.feed = -1}
		}
		for cl in color_change_layers {
			if cl == layer.layer_index {cur_state.feed = -1}
		}
		cur_state.z = layer.z
		cur_state.physical_z = klipper_layer_start_z(motion, layer)

		found_accel := false
		found_fan := false
		found_xy := false
		found_feed := false
		for i := op_end-1; i >= op_start; i -= 1 {
			op := motion.operations[i]
			if !found_accel && (op.kind == .Travel || op.kind == .Extrude) {
				cur_state.acceleration = i64(op.acceleration)/1_000
				found_accel = true
			}
			if !found_fan && op.kind == .Extrude {
				cur_state.fan_pwm = klipper_fan_pwm(op.fan_ratio)
				found_fan = true
			}
			if !found_xy && (op.kind == .Travel || op.kind == .Extrude) {
				cur_state.positioned_xy = true
				cur_state.x = op.point_b.x
				cur_state.y = op.point_b.y
				found_xy = true
			}
			if !found_feed && op.kind != .Dwell {
				cur_state.feed = klipper_feed_rate(op.speed)
				found_feed = true
			}
			if found_accel && found_fan && found_xy && found_feed {break}
		}
		if !cur_state.positioned_xy {
			for i in op_start..<op_end {
				op := motion.operations[i]
				if op.kind != .Dwell {
					cur_state.positioned_xy = true
					cur_state.x = op.point_a.x
					cur_state.y = op.point_a.y
					break
				}
			}
		}
	}

	pctx := Klipper_Parallel_Context{
		motion              = motion,
		profile             = profile,
		pause_layers        = pause_layers,
		color_change_layers = color_change_layers,
		allocator           = worker_allocator,
		layers              = layer_emits,
		record_commands     = record_commands,
	}
	workers.parallel_for(layer_count, &pctx, klipper_emit_layer_worker, g_gcode_worker_threads)

	header_text := transmute([]u8)strings.to_string(header_builder)
	footer_text := transmute([]u8)strings.to_string(footer_builder)
	total_bytes := u64(len(header_text))
	total_cmds := u64(header_cmd_write)
	result := Klipper_Result{
		schema_version         = KLIPPER_EMITTER_SCHEMA_VERSION,
		layer_count            = u32(layer_count),
		motion_operation_count = u64(len(motion.operations)),
	}
	cut_count := 0
	for &le, li in layer_emits {
		if !le.ok {return {}, .Command_Limit}
		if li+1 < layer_count {
			next_init := layer_emits[li+1].init_state
			if le.end_state.acceleration != next_init.acceleration ||
			   le.end_state.feed != next_init.feed ||
			   le.end_state.fan_pwm != next_init.fan_pwm ||
			   le.end_state.positioned_xy != next_init.positioned_xy ||
			   le.end_state.x != next_init.x ||
			   le.end_state.y != next_init.y ||
			   le.end_state.z != next_init.z {
				return {}, .Invalid_Motion
			}
		}
		le.byte_offset = total_bytes
		le.command_offset = total_cmds
		if le.has_cut {cut_count += 1}
		total_bytes += u64(len(le.builder.buf))
		total_cmds += u64(le.command_count)
		result.positive_filament_nm += le.positive_filament_nm
		result.negative_filament_nm += le.negative_filament_nm
		result.emitted_dwell_ms += le.emitted_dwell_ms
	}
	footer_byte_offset := total_bytes
	footer_cmd_offset := total_cmds
	total_bytes += u64(len(footer_text))
	total_cmds += u64(footer_cmd_write)
	if total_bytes > limits.max_bytes || total_bytes > u64(max(int)) {
		return {}, .Byte_Limit
	}
	if total_cmds > limits.max_commands || total_cmds > u64(max(int)) {
		return {}, .Command_Limit
	}

	result.bytes = make([]u8, int(total_bytes), allocator)
	if record_commands {
		result.commands = make([]Klipper_Command_Record, int(total_cmds), allocator)
	}
	result.plan_cuts = make([]Klipper_Plan_Cut, cut_count, allocator)
	if (total_bytes > 0 && result.bytes == nil) ||
	   (record_commands && total_cmds > 0 && result.commands == nil) ||
	   (cut_count > 0 && result.plan_cuts == nil) {
		klipper_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	cut_write := 0
	for le in layer_emits {
		if !le.has_cut {continue}
		cut := le.cut
		cut.byte_offset += le.byte_offset
		result.plan_cuts[cut_write] = cut
		cut_write += 1
	}

	copy(result.bytes[:len(header_text)], header_text)
	copy(result.bytes[footer_byte_offset:], footer_text)
	if record_commands {
		copy(result.commands[:header_cmd_write], header_cmds[:header_cmd_write])
		for i in 0..<footer_cmd_write {
			cmd := footer_cmds[i]
			gidx := footer_cmd_offset+u64(i)
			parent := cmd.source_operation_id
			if parent == contracts.INVALID_STABLE_ID {parent = contracts.Stable_ID(1)}
			cmd.command_index = u32(gidx)
			cmd.byte_offset += footer_byte_offset
			cmd.stable_id = contracts.stable_id_child(parent, .Command, gidx)
			result.commands[gidx] = cmd
		}
	}

	last_end := layer_emits[layer_count-1].end_state
	result.final_x = last_end.x
	result.final_y = last_end.y
	result.final_z = last_end.z

	pctx.out_bytes = result.bytes
	pctx.out_commands = result.commands
	workers.parallel_for(layer_count, &pctx, klipper_assemble_and_validate_layer, g_gcode_worker_threads)

	// Validate header, check per-layer validation + cross-layer state continuity, and validate footer.
	hdr_state, report, hdr_val_err := klipper_validate_header_slice(result.bytes[:len(header_text)], profile, motion)
	if hdr_val_err != .None || !klipper_cruise_ratio_reported(report, minimum_cruise_ratio_ppm) {
		klipper_result_destroy(&result, allocator)
		return {}, .Invalid_Motion
	}
	if hdr_state.acceleration != layer_emits[0].init_state.acceleration ||
	   hdr_state.feed != layer_emits[0].init_state.feed ||
	   hdr_state.fan_pwm != layer_emits[0].init_state.fan_pwm ||
	   hdr_state.positioned_xy != layer_emits[0].init_state.positioned_xy {
		klipper_result_destroy(&result, allocator)
		return {}, .Invalid_Motion
	}
	for le, li in layer_emits {
		if le.val_error != .None {
			klipper_result_destroy(&result, allocator)
			return {}, .Invalid_Motion
		}
		if li+1 < layer_count {
			next_init := layer_emits[li+1].init_state
			if le.val_end_state.acceleration != next_init.acceleration ||
			   le.val_end_state.feed != next_init.feed ||
			   le.val_end_state.fan_pwm != next_init.fan_pwm ||
			   le.val_end_state.positioned_xy != next_init.positioned_xy ||
			   le.val_end_state.x != i64(next_init.x) ||
			   le.val_end_state.y != i64(next_init.y) ||
			   le.val_end_state.z != i64(next_init.z) ||
			   le.val_end_state.z_hop_stage != 0 {
				klipper_result_destroy(&result, allocator)
				return {}, .Invalid_Motion
			}
		}
		report.command_count += le.val_report.command_count
		report.motion_operation_count += le.val_report.motion_operation_count
		report.positive_filament_nm += le.val_report.positive_filament_nm
		report.negative_filament_nm += le.val_report.negative_filament_nm
		report.dwell_ms += le.val_report.dwell_ms
	}
	report.layer_count = u32(layer_count)
	last_val := layer_emits[layer_count-1].val_end_state
	report.final_x = contracts.Micrometres(last_val.x)
	report.final_y = contracts.Micrometres(last_val.y)
	report.final_z = contracts.Micrometres(last_val.z)
	report.final_fan_pwm = layer_emits[layer_count-1].val_report.final_fan_pwm

	ftr_val_err := klipper_validate_footer_slice(result.bytes[footer_byte_offset:], profile, &report)
	if ftr_val_err != .None ||
	   report.minimum_cruise_ratio_restored != (minimum_cruise_ratio_ppm >= 0) ||
	   report.command_count != total_cmds ||
	   report.motion_operation_count != u64(len(motion.operations)) ||
	   report.positive_filament_nm != result.positive_filament_nm ||
	   report.negative_filament_nm != result.negative_filament_nm ||
	   report.dwell_ms != result.emitted_dwell_ms ||
	   report.final_x != result.final_x ||
	   report.final_y != result.final_y ||
	   report.final_z != result.final_z {
		klipper_result_destroy(&result, allocator)
		return {}, .Invalid_Motion
	}
	result.validation = report
	return result, .None
}

@(private = "file")
klipper_emit_layer_worker :: proc(ctx: ^Klipper_Parallel_Context, li: int) {
	le := &ctx.layers[li]
	layer := ctx.motion.layers[li]
	state := le.init_state
	op_count := int(layer.operation_count)
	est_bytes := max(256, op_count*48+128)
	max_cmds := op_count*5+8
	builder, b_err := strings.builder_make(0, est_bytes, ctx.allocator)
	if b_err != nil {return}
	cmds: []Klipper_Command_Record
	if ctx.record_commands {
		cmds = make([]Klipper_Command_Record, max_cmds, ctx.allocator)
		if cmds == nil {
			strings.builder_destroy(&builder)
			return
		}
	}
	cmd_write := 0
	local_res := Klipper_Result{}

	start := klipper_command_begin(builder)
	fmt.sbprintf(&builder, ";LAYER:%d Z:", layer.layer_index)
	klipper_append_coordinate(&builder, layer.z)
	strings.write_string(&builder, "\n")
	if !klipper_command_end_deferred(builder, cmds, &cmd_write, .Comment, start, layer_index = layer.layer_index) {
		strings.builder_destroy(&builder)
		delete(cmds, ctx.allocator)
		return
	}
	start = klipper_command_begin(builder)
	fmt.sbprintf(&builder, "SET_PRINT_STATS_INFO CURRENT_LAYER=%d\n", layer.layer_index+1)
	if !klipper_command_end_deferred(builder, cmds, &cmd_write, .Set_Print_Stats, start, layer_index = layer.layer_index) {
		strings.builder_destroy(&builder)
		delete(cmds, ctx.allocator)
		return
	}
	if !klipper_emit_acceleration(
		&builder,
		cmds,
		&cmd_write,
		&state,
		.Travel,
		ctx.profile.process.source.travel.acceleration,
		{},
		layer.layer_index,
	) {
		strings.builder_destroy(&builder)
		delete(cmds, ctx.allocator)
		return
	}
	layer_start_z := klipper_layer_start_z(ctx.motion, layer)
	start = klipper_command_begin(builder)
	strings.write_string(&builder, "G0 Z")
	klipper_append_coordinate(&builder, layer_start_z)
	klipper_append_feed(&builder, &state, klipper_feed_rate(ctx.profile.process.source.travel.speed))
	if !klipper_command_end_deferred(builder, cmds, &cmd_write, .Move, start, layer_index = layer.layer_index) {
		strings.builder_destroy(&builder)
		delete(cmds, ctx.allocator)
		return
	}
	state.z = layer.z
	state.physical_z = layer_start_z

	for pl in ctx.pause_layers {
		if pl == layer.layer_index {
			if !klipper_write_literal(&builder, cmds, &cmd_write, .Pause_Or_Filament, "PAUSE\n", {}, layer.layer_index) {
				strings.builder_destroy(&builder)
				delete(cmds, ctx.allocator)
				return
			}
			state.feed = -1
			break
		}
	}
	for cl in ctx.color_change_layers {
		if cl == layer.layer_index {
			if !klipper_write_literal(&builder, cmds, &cmd_write, .Pause_Or_Filament, "M600\n", {}, layer.layer_index) {
				strings.builder_destroy(&builder)
				delete(cmds, ctx.allocator)
				return
			}
			state.feed = -1
			break
		}
	}

	op_start := int(layer.operation_offset)
	op_end := op_start+op_count
	for operation in ctx.motion.operations[op_start:op_end] {
		if !state.positioned_xy && operation.kind != .Dwell {
			start = klipper_command_begin(builder)
			strings.write_string(&builder, "G0 X")
			klipper_append_coordinate(&builder, operation.point_a.x)
			strings.write_string(&builder, " Y")
			klipper_append_coordinate(&builder, operation.point_a.y)
			klipper_append_feed(&builder, &state, klipper_feed_rate(ctx.profile.process.source.travel.speed))
			if !klipper_command_end_deferred(builder, cmds, &cmd_write, .Move, start, layer_index = layer.layer_index) {
				strings.builder_destroy(&builder)
				delete(cmds, ctx.allocator)
				return
			}
			state.positioned_xy = true
			state.x = operation.point_a.x
			state.y = operation.point_a.y
		}
		if !le.has_cut && klipper_plan_cut_operation(operation.kind) && state.feed >= 0 {
			le.cut = klipper_plan_cut(state, u64(len(builder.buf)))
			le.has_cut = true
		}
		if !klipper_emit_operation(&builder, cmds, &cmd_write, &state, operation, &local_res) {
			strings.builder_destroy(&builder)
			delete(cmds, ctx.allocator)
			return
		}
	}

	le.builder = builder
	le.commands_buf = cmds
	le.command_count = cmd_write
	le.end_state = state
	le.positive_filament_nm = local_res.positive_filament_nm
	le.negative_filament_nm = local_res.negative_filament_nm
	le.emitted_dwell_ms = local_res.emitted_dwell_ms
	le.ok = true
}

@(private = "file")
klipper_command_end_deferred :: proc(
	builder: strings.Builder,
	commands: []Klipper_Command_Record,
	command_write: ^int,
	kind: Klipper_Command_Kind,
	start: int,
	source_operation_id := contracts.INVALID_STABLE_ID,
	layer_index := max(u32),
) -> bool {
	end := len(strings.to_string(builder))
	if end <= start || end-start > int(max(u32)) {return false}
	if commands != nil {
		if command_write^ >= len(commands) {return false}
		commands[command_write^] = {
			kind                = kind,
			byte_offset         = u64(start),
			byte_count          = u32(end-start),
			source_operation_id = source_operation_id,
			layer_index         = layer_index,
		}
	}
	command_write^ += 1
	return true
}

@(private = "file")
klipper_assemble_and_validate_layer :: proc(ctx: ^Klipper_Parallel_Context, li: int) {
	le := &ctx.layers[li]
	src_bytes := le.builder.buf[:]
	dst_bytes := ctx.out_bytes[le.byte_offset : le.byte_offset+u64(len(src_bytes))]
	copy(dst_bytes, src_bytes)
	if ctx.record_commands {
		for cmd, i in le.commands_buf[:le.command_count] {
			gidx := le.command_offset+u64(i)
			parent := cmd.source_operation_id
			if parent == contracts.INVALID_STABLE_ID {parent = contracts.Stable_ID(1)}
			out := cmd
			out.command_index = u32(gidx)
			out.byte_offset += le.byte_offset
			out.stable_id = contracts.stable_id_child(parent, .Command, gidx)
			ctx.out_commands[gidx] = out
		}
	}
	le.val_end_state, le.val_report, le.val_error = klipper_validate_layer_slice(
		dst_bytes,
		u32(li),
		le.init_state,
		ctx.profile,
		ctx.motion,
	)
}

klipper_emit_operation :: proc(
	builder: ^strings.Builder,
	commands: []Klipper_Command_Record,
	command_write: ^int,
	state: ^Klipper_State,
	operation: features.Motion_Operation,
	result: ^Klipper_Result,
) -> bool {
	acceleration_kind := operation.kind
	if !klipper_emit_acceleration(
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
		pwm := klipper_fan_pwm(operation.fan_ratio)
		if pwm != state.fan_pwm {
			start := klipper_command_begin(builder^)
			if pwm == 0 {
				strings.write_string(builder, "M107\n")
			} else {
				fmt.sbprintf(builder, "M106 S%d\n", pwm)
			}
			if !klipper_command_end(
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
	start := klipper_command_begin(builder^)
	switch operation.kind {
	case .Retract, .Recover:
		strings.write_string(builder, "G1 E")
		klipper_append_extrusion(builder, operation.filament_delta_nm)
		klipper_append_feed(builder, state, klipper_feed_rate(operation.speed))
	case .Travel:
		travel_z := contracts.Micrometres(max(i64(0), i64(state.z)+i64(operation.z_offset_um)))
		if i64(operation.z_hop_um) > 0 {
			hop_z := contracts.Micrometres(i64(state.z) + i64(operation.z_hop_um))
			strings.write_string(builder, "G0 Z")
			klipper_append_coordinate(builder, hop_z)
			klipper_append_feed(builder, state, klipper_feed_rate(operation.speed))
			if !klipper_command_end(
				builder^,
				commands,
				command_write,
				.Move,
				start,
				operation.stable_id,
				operation.layer_index,
			) {
				return false
			}
			start = klipper_command_begin(builder^)
		}
		strings.write_string(builder, "G0 X")
		klipper_append_coordinate(builder, operation.point_b.x)
		strings.write_string(builder, " Y")
		klipper_append_coordinate(builder, operation.point_b.y)
		if i64(operation.z_hop_um) <= 0 && state.physical_z != travel_z {
			strings.write_string(builder, " Z")
			klipper_append_coordinate(builder, travel_z)
			state.physical_z = travel_z
		}
		klipper_append_feed(builder, state, klipper_feed_rate(operation.speed))
		if i64(operation.z_hop_um) > 0 {
			if !klipper_command_end(
				builder^,
				commands,
				command_write,
				.Move,
				start,
				operation.stable_id,
				operation.layer_index,
			) {
				return false
			}
			start = klipper_command_begin(builder^)
			strings.write_string(builder, "G0 Z")
			klipper_append_coordinate(builder, travel_z)
			klipper_append_feed(builder, state, klipper_feed_rate(operation.speed))
			state.physical_z = travel_z
		}
	case .Extrude:
		target_z := contracts.Micrometres(max(i64(0), i64(state.z) + i64(operation.z_offset_um)))
		if operation.arc != .None {
			strings.write_string(builder, "G2 X" if operation.arc == .CW else "G3 X")
			klipper_append_coordinate(builder, operation.point_b.x)
			strings.write_string(builder, " Y")
			klipper_append_coordinate(builder, operation.point_b.y)
			if target_z != state.physical_z {
				strings.write_string(builder, " Z")
				klipper_append_coordinate(builder, target_z)
				state.physical_z = target_z
			}
			strings.write_string(builder, " I")
			klipper_append_coordinate(builder, contracts.Micrometres(i64(operation.arc_center.x)-i64(operation.point_a.x)))
			strings.write_string(builder, " J")
			klipper_append_coordinate(builder, contracts.Micrometres(i64(operation.arc_center.y)-i64(operation.point_a.y)))
			strings.write_string(builder, " E")
			klipper_append_extrusion(builder, operation.filament_delta_nm)
			klipper_append_feed(builder, state, klipper_feed_rate(operation.speed))
		} else {
			strings.write_string(builder, "G1 X")
			klipper_append_coordinate(builder, operation.point_b.x)
			strings.write_string(builder, " Y")
			klipper_append_coordinate(builder, operation.point_b.y)
			if target_z != state.physical_z {
				strings.write_string(builder, " Z")
				klipper_append_coordinate(builder, target_z)
				state.physical_z = target_z
			}
			strings.write_string(builder, " E")
			klipper_append_extrusion(builder, operation.filament_delta_nm)
			klipper_append_feed(builder, state, klipper_feed_rate(operation.speed))
		}
	case .Dwell:
		dwell_ms := (operation.duration_us+999)/1_000
		fmt.sbprintf(builder, "G4 P%d\n", dwell_ms)
		result.emitted_dwell_ms += dwell_ms
	case .Invalid:
		return false
	}
	if !klipper_command_end(
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

// The bounding rectangle of all extrusion endpoints (and arc bounds), which START_PRINT
// receives as the print area. A valid motion plan has at least one extrusion.
klipper_extrusion_area :: proc(motion: features.Motion_Plan_Result) -> (area: [2]polygon.Polygon_Point) {
	area = {{max(contracts.Micrometres), max(contracts.Micrometres)}, {min(contracts.Micrometres), min(contracts.Micrometres)}}
	for operation in motion.operations {
		if operation.kind != .Extrude {continue}
		for point in ([2]polygon.Polygon_Point{operation.point_a, operation.point_b}) {
			area[0] = {min(area[0].x, point.x), min(area[0].y, point.y)}
			area[1] = {max(area[1].x, point.x), max(area[1].y, point.y)}
		}
		if operation.arc != .None {
			dx := f64(i64(operation.point_a.x)-i64(operation.arc_center.x))
			dy := f64(i64(operation.point_a.y)-i64(operation.arc_center.y))
			r := contracts.Micrometres(i64(math.ceil(math.hypot(dx, dy))))
			area[0] = {min(area[0].x, operation.arc_center.x-r), min(area[0].y, operation.arc_center.y-r)}
			area[1] = {max(area[1].x, operation.arc_center.x+r), max(area[1].y, operation.arc_center.y+r)}
		}
	}
	return
}

// Klipper splits extended G-code parameters on whitespace, so object names keep only
// [A-Za-z0-9_.-] and replace every other byte with '_'.
klipper_object_name :: proc(name: string, allocator := context.allocator) -> string {
	if len(name) == 0 {return strings.clone("object", allocator)}
	out := make([]u8, len(name), allocator)
	for i in 0..<len(name) {
		c := name[i]
		switch c {
		case 'A'..='Z', 'a'..='z', '0'..='9', '_', '.', '-':
			out[i] = c
		case:
			out[i] = '_'
		}
	}
	return string(out)
}

// The Z that a layer starts at: for a leading travel, the travel's ramped Z; for a leading
// Z-ramped extrusion (spiral vase or scarf seam), the previous layer's Z when it is at or below
// the first segment's endpoint so segment 0 ramps smoothly instead of jumping vertically first.
klipper_layer_start_z :: proc(motion: features.Motion_Plan_Result, layer: features.Motion_Layer) -> contracts.Micrometres {
	operation_start := int(layer.operation_offset)
	operation_end := operation_start+int(layer.operation_count)
	for operation in motion.operations[operation_start:operation_end] {
		if operation.kind == .Travel {
			return contracts.Micrometres(max(i64(0), i64(layer.z)+i64(operation.z_offset_um)))
		}
		if operation.kind == .Extrude {
			end_z := contracts.Micrometres(max(i64(0), i64(layer.z)+i64(operation.z_offset_um)))
			if operation.z_offset_um < 0 && layer.layer_index > 0 && int(layer.layer_index)-1 < len(motion.layers) {
				prev_z := motion.layers[layer.layer_index-1].z
				if prev_z <= end_z {
					return prev_z
				}
			}
			return end_z
		}
	}
	return layer.z
}

klipper_emit_acceleration :: proc(
	builder: ^strings.Builder,
	commands: []Klipper_Command_Record,
	command_write: ^int,
	state: ^Klipper_State,
	operation_kind: features.Motion_Operation_Kind,
	acceleration: profiles.Acceleration_Um_Per_Second_Squared,
	source_operation_id: contracts.Stable_ID,
	layer_index: u32,
) -> bool {
	// Klipper limits extrude-only moves by max_extrude_only_accel, not the toolhead acceleration.
	if operation_kind == .Dwell || operation_kind == .Retract || operation_kind == .Recover {return true}
	if operation_kind == .Invalid {return false}
	value := i64(acceleration)/1_000
	current := &state.acceleration
	if current^ == value {return true}
	start := klipper_command_begin(builder^)
	strings.write_string(builder, "M204 S")
	klipper_append_uint(builder, u64(value))
	strings.write_byte(builder, '\n')
	if !klipper_command_end(
		builder^,
		commands,
		command_write,
		.Set_Acceleration,
		start,
		source_operation_id,
		layer_index,
	) {
		return false
	}
	current^ = value
	return true
}

klipper_motion_valid :: proc(
	motion: features.Motion_Plan_Result,
	profile: profiles.Resolved_Profiles,
	require_stable_ids := true,
) -> bool {
	n_layers := len(motion.layers)
	if n_layers == 0 || motion.extrusion_count == 0 {
		return false
	}
	expected_offset: u64
	total_motion: u64
	total_dwell: u64
	total_planned: u64
	previous_z := i64(profile.printer.axis_minimum_z)
	for layer, layer_index in motion.layers {
		layer_z := i64(layer.z)
		operation_limit := layer.operation_offset+u64(layer.operation_count)
		duration_sum, duration_ok := klipper_checked_add_u64(
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
		total_motion, duration_ok = klipper_checked_add_u64(total_motion, layer.motion_duration_us)
		if duration_ok {
			total_dwell, duration_ok = klipper_checked_add_u64(total_dwell, layer.dwell_duration_us)
		}
		if duration_ok {
			total_planned, duration_ok = klipper_checked_add_u64(total_planned, layer.planned_duration_us)
		}
		if !duration_ok {return false}
		expected_offset += u64(layer.operation_count)
	}
	if expected_offset != u64(len(motion.operations)) ||
	   total_motion != motion.total_motion_duration_us ||
	   total_dwell != motion.total_dwell_duration_us ||
	   total_planned != motion.total_planned_duration_us {
		return false
	}

	Motion_Valid_Layer :: struct {
		retraction_count: u64,
		travel_count:     u64,
		extrusion_count:  u64,
		dwell_count:      u64,
		ok:               bool,
	}
	Motion_Valid_Ctx :: struct {
		motion:             features.Motion_Plan_Result,
		profile:            profiles.Resolved_Profiles,
		require_stable_ids: bool,
		out:                []Motion_Valid_Layer,
	}
	out := make([]Motion_Valid_Layer, n_layers, context.temp_allocator)
	vctx := Motion_Valid_Ctx{
		motion             = motion,
		profile            = profile,
		require_stable_ids = require_stable_ids,
		out                = out,
	}
	workers.parallel_for(n_layers, &vctx, proc(c: ^Motion_Valid_Ctx, layer_index: int) {
		layer := c.motion.layers[layer_index]
		operation_start := int(layer.operation_offset)
		operation_end := operation_start+int(layer.operation_count)
		layer_motion: u64
		layer_dwell: u64
		retraction_count: u64
		travel_count: u64
		extrusion_count: u64
		dwell_count: u64
		req_ids := c.require_stable_ids
		for operation in c.motion.operations[operation_start:operation_end] {
			if (req_ids && operation.stable_id == contracts.INVALID_STABLE_ID) ||
			   operation.layer_index != u32(layer_index) ||
			   operation.duration_us == 0 ||
			   !klipper_operation_numeric_valid(operation, c.profile) {
				return
			}
			duration_ok: bool
			if operation.kind == .Dwell {
				layer_dwell, duration_ok = klipper_checked_add_u64(layer_dwell, operation.duration_us)
				dwell_count += 1
			} else {
				layer_motion, duration_ok = klipper_checked_add_u64(layer_motion, operation.duration_us)
			}
			if !duration_ok {return}
			switch operation.kind {
			case .Retract:
				if operation.filament_delta_nm >= 0 {return}
				retraction_count += 1
			case .Travel:
				if operation.filament_delta_nm != 0 ||
				   operation.role != .Invalid ||
				   operation.point_a == operation.point_b {
					return
				}
				travel_count += 1
			case .Recover:
				if operation.filament_delta_nm <= 0 {return}
			case .Extrude:
				if operation.filament_delta_nm <= 0 ||
				   operation.role == .Invalid ||
				   operation.point_a == operation.point_b {
					return
				}
				extrusion_count += 1
			case .Dwell:
				if operation.filament_delta_nm != 0 ||
				   operation.speed != 0 ||
				   operation.acceleration != 0 ||
				   operation.point_a != operation.point_b {
					return
				}
			case .Invalid:
				return
			}
		}
		if layer.motion_duration_us != layer_motion ||
		   layer.dwell_duration_us != layer_dwell {
			return
		}
		c.out[layer_index] = {
			retraction_count = retraction_count,
			travel_count     = travel_count,
			extrusion_count  = extrusion_count,
			dwell_count      = dwell_count,
			ok               = true,
		}
	}, g_gcode_worker_threads)

	retraction_count: u64
	travel_count: u64
	extrusion_count: u64
	dwell_count: u64
	for r in out {
		if !r.ok {return false}
		retraction_count += r.retraction_count
		travel_count += r.travel_count
		extrusion_count += r.extrusion_count
		dwell_count += r.dwell_count
	}
	return retraction_count == motion.retraction_count &&
		travel_count == motion.travel_count &&
		extrusion_count == motion.extrusion_count &&
		dwell_count == motion.dwell_count
}

klipper_operation_numeric_valid :: proc(
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
		// Each extrusion carries its own feature's motion and cooling, so the bounds are the
		// machine and material limits, not one setting per role.
		_, role_ok := features.motion_role_target(profile.process, operation.role)
		return role_ok &&
			i64(operation.speed) >= i64(process.minimum_print_speed) &&
			i64(operation.speed) <= i64(profile.printer.maximum_speed) &&
			i64(operation.acceleration) <= i64(profile.printer.maximum_acceleration) &&
			u32(operation.fan_ratio) >= u32(profile.material.minimum_fan_ratio) &&
			u32(operation.fan_ratio) <= u32(profile.material.maximum_fan_ratio)
	case .Dwell:
		return true
	case .Invalid:
		return false
	}
	return false
}

klipper_write_literal :: proc(
	builder: ^strings.Builder,
	commands: []Klipper_Command_Record,
	command_write: ^int,
	kind: Klipper_Command_Kind,
	line: string,
	source_operation_id := contracts.INVALID_STABLE_ID,
	layer_index := max(u32),
) -> bool {
	start := klipper_command_begin(builder^)
	strings.write_string(builder, line)
	return klipper_command_end(
		builder^,
		commands,
		command_write,
		kind,
		start,
		source_operation_id,
		layer_index,
	)
}

klipper_command_begin :: proc(builder: strings.Builder) -> int {
	return len(strings.to_string(builder))
}

klipper_command_end :: proc(
	builder: strings.Builder,
	commands: []Klipper_Command_Record,
	command_write: ^int,
	kind: Klipper_Command_Kind,
	start: int,
	source_operation_id := contracts.INVALID_STABLE_ID,
	layer_index := max(u32),
) -> bool {
	end := len(strings.to_string(builder))
	if end <= start || end-start > int(max(u32)) {
		return false
	}
	if commands != nil {
		if command_write^ >= len(commands) {return false}
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
	}
	command_write^ += 1
	return true
}

@(private = "file")
KLIPPER_DIGITS_2 := [200]u8{
	'0','0','0','1','0','2','0','3','0','4','0','5','0','6','0','7','0','8','0','9',
	'1','0','1','1','1','2','1','3','1','4','1','5','1','6','1','7','1','8','1','9',
	'2','0','2','1','2','2','2','3','2','4','2','5','2','6','2','7','2','8','2','9',
	'3','0','3','1','3','2','3','3','3','4','3','5','3','6','3','7','3','8','3','9',
	'4','0','4','1','4','2','4','3','4','4','4','5','4','6','4','7','4','8','4','9',
	'5','0','5','1','5','2','5','3','5','4','5','5','5','6','5','7','5','8','5','9',
	'6','0','6','1','6','2','6','3','6','4','6','5','6','6','6','7','6','8','6','9',
	'7','0','7','1','7','2','7','3','7','4','7','5','7','6','7','7','7','8','7','9',
	'8','0','8','1','8','2','8','3','8','4','8','5','8','6','8','7','8','8','8','9',
	'9','0','9','1','9','2','9','3','9','4','9','5','9','6','9','7','9','8','9','9',
}

klipper_append_coordinate :: #force_inline proc(
	builder: ^strings.Builder,
	value: contracts.Micrometres,
) {
	klipper_append_fixed_u64(builder, i64(value), 3)
}

klipper_append_extrusion :: #force_inline proc(builder: ^strings.Builder, value_nm: i128) {
	if value_nm >= i128(min(i64)) && value_nm <= i128(max(i64)) {
		klipper_append_fixed_u64(builder, i64(value_nm) / 10, 5)
		return
	}
	klipper_append_fixed(builder, value_nm / 10, 5)
}

klipper_append_feed :: proc(builder: ^strings.Builder, state: ^Klipper_State, feed: i64) {
	if state.feed != feed {
		strings.write_string(builder, " F")
		klipper_append_uint(builder, u64(feed))
		state.feed = feed
	}
	strings.write_byte(builder, '\n')
}

klipper_append_uint :: proc(builder: ^strings.Builder, value: u64) {
	buf: [24]u8
	pos := len(buf)
	v := value
	if v == 0 {
		pos -= 1; buf[pos] = '0'
	} else {
		for v >= 100 {
			r := (v % 100) * 2
			v /= 100
			pos -= 2
			buf[pos] = KLIPPER_DIGITS_2[r]
			buf[pos + 1] = KLIPPER_DIGITS_2[r + 1]
		}
		if v >= 10 {
			r := v * 2
			pos -= 2
			buf[pos] = KLIPPER_DIGITS_2[r]
			buf[pos + 1] = KLIPPER_DIGITS_2[r + 1]
		} else {
			pos -= 1
			buf[pos] = u8('0' + v)
		}
	}
	strings.write_bytes(builder, buf[pos:])
}

klipper_write_cruise_ratio :: proc(
	builder: ^strings.Builder,
	commands: []Klipper_Command_Record,
	command_write: ^int,
	ratio_ppm: i64,
) -> bool {
	if ratio_ppm < 0 {return true}
	if ratio_ppm >= i64(profiles.RATIO_SCALE) {return false}
	start := klipper_command_begin(builder^)
	fmt.sbprintf(builder, "SET_VELOCITY_LIMIT MINIMUM_CRUISE_RATIO=0.%06d\n", ratio_ppm)
	return klipper_command_end(builder^, commands, command_write, .Set_Acceleration, start)
}

klipper_write_cruise_ratio_restore :: proc(
	builder: ^strings.Builder,
	commands: []Klipper_Command_Record,
	command_write: ^int,
	profile: profiles.Resolved_Profiles,
	ratio_ppm: i64,
) -> bool {
	if ratio_ppm < 0 {return true}
	return klipper_write_cruise_ratio(builder, commands, command_write, i64(profile.printer.minimum_cruise_ratio))
}

klipper_cruise_ratio_reported :: proc(report: Klipper_Validation_Report, ratio_ppm: i64) -> bool {
	if ratio_ppm < 0 {return !report.has_minimum_cruise_ratio}
	return report.has_minimum_cruise_ratio && report.minimum_cruise_ratio_ppm == ratio_ppm
}

klipper_plan_cut_operation :: proc(kind: features.Motion_Operation_Kind) -> bool {
	return kind == .Retract || kind == .Recover || kind == .Dwell
}

klipper_plan_cut :: proc(state: Klipper_State, byte_offset: u64) -> Klipper_Plan_Cut {
	return {
		byte_offset  = byte_offset,
		x            = state.x,
		y            = state.y,
		z            = state.physical_z,
		feed         = state.feed,
		acceleration = state.acceleration,
	}
}

@(private = "file")
klipper_append_fixed_u64 :: #force_inline proc(
	builder: ^strings.Builder,
	units: i64,
	$decimal_places: u8,
) {
	negative := units < 0
	magnitude := u64(-units if negative else units)
	when decimal_places == 3 {
		whole := magnitude / 1_000
		frac := magnitude % 1_000
	} else {
		whole := magnitude / 100_000
		frac := magnitude % 100_000
	}
	buf: [32]u8
	pos := len(buf)
	when decimal_places == 3 {
		d2 := (frac % 100) * 2
		pos -= 3
		buf[pos] = u8('0' + frac / 100)
		buf[pos + 1] = KLIPPER_DIGITS_2[d2]
		buf[pos + 2] = KLIPPER_DIGITS_2[d2 + 1]
	} else {
		d2 := (frac % 100) * 2
		frac /= 100
		d4 := (frac % 100) * 2
		pos -= 5
		buf[pos] = u8('0' + frac / 100)
		buf[pos + 1] = KLIPPER_DIGITS_2[d4]
		buf[pos + 2] = KLIPPER_DIGITS_2[d4 + 1]
		buf[pos + 3] = KLIPPER_DIGITS_2[d2]
		buf[pos + 4] = KLIPPER_DIGITS_2[d2 + 1]
	}
	pos -= 1; buf[pos] = '.'
	if whole == 0 {
		pos -= 1; buf[pos] = '0'
	} else {
		for whole >= 100 {
			r := (whole % 100) * 2
			whole /= 100
			pos -= 2
			buf[pos] = KLIPPER_DIGITS_2[r]
			buf[pos + 1] = KLIPPER_DIGITS_2[r + 1]
		}
		if whole >= 10 {
			r := whole * 2
			pos -= 2
			buf[pos] = KLIPPER_DIGITS_2[r]
			buf[pos + 1] = KLIPPER_DIGITS_2[r + 1]
		} else {
			pos -= 1
			buf[pos] = u8('0' + whole)
		}
	}
	if negative {
		pos -= 1; buf[pos] = '-'
	}
	strings.write_bytes(builder, buf[pos:])
}

klipper_append_fixed :: proc(
	builder: ^strings.Builder,
	units: i128,
	decimal_places: u8,
) {
	negative := units < 0
	magnitude := u64(-units if negative else units)
	scale: u64
	switch decimal_places {
	case 3: scale = 1_000
	case 5: scale = 100_000
	case:
		return
	}
	whole := magnitude / scale
	frac := magnitude % scale
	buf: [32]u8
	pos := len(buf)
	for _ in 0 ..< int(decimal_places) {
		pos -= 1
		buf[pos] = u8('0' + (frac % 10))
		frac /= 10
	}
	pos -= 1; buf[pos] = '.'
	if whole == 0 {
		pos -= 1; buf[pos] = '0'
	} else {
		for whole > 0 {
			pos -= 1
			buf[pos] = u8('0' + (whole % 10))
			whole /= 10
		}
	}
	if negative {
		pos -= 1; buf[pos] = '-'
	}
	strings.write_bytes(builder, buf[pos:])
}

klipper_feed_rate :: proc(speed: profiles.Speed_Um_Per_Second) -> i64 {
	return i64(speed)*60/1_000
}

klipper_fan_pwm :: proc(ratio: profiles.Ratio_Ppm) -> i32 {
	return i32(
		(u64(u32(ratio))*255+u64(profiles.RATIO_SCALE/2))/
		u64(profiles.RATIO_SCALE),
	)
}

klipper_checked_add_u64 :: proc(a, b: u64) -> (u64, bool) {
	if b > max(u64)-a {return 0, false}
	return a+b, true
}

klipper_result_destroy :: proc(
	result: ^Klipper_Result,
	allocator := context.allocator,
) {
	delete(result.bytes, allocator)
	delete(result.commands, allocator)
	delete(result.plan_cuts, allocator)
	result^ = {}
}
