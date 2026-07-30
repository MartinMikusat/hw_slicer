package gcode

import "core:strings"
import "core:testing"

import contracts "../contracts"
import features "../features"
import polygon "../polygon"
import profiles "../profiles"

@(test)
marlin_emits_structured_single_extruder_file_test :: proc(t: ^testing.T) {
	profile := marlin_test_profile(t)
	motion := marlin_test_motion()
	defer features.motion_plan_result_destroy(&motion)
	result, error := marlin_emit(motion, profile)
	defer marlin_result_destroy(&result)
	testing.expect_value(t, error, Marlin_Error.None)
	text := string(result.bytes)
	testing.expect(t, strings.contains(text, "G21\nG90\nM83\n"))
	testing.expect(t, strings.contains(text, "G28\nM190 S60\nM420 S1\n"))
	testing.expect(t, strings.contains(text, "M109 S210\n"))
	testing.expect(t, strings.contains(text, "M204 P1000\n"))
	testing.expect(t, strings.contains(text, "M204 R1000\n"))
	testing.expect(t, strings.contains(text, "M204 T2000\n"))
	testing.expect(t, strings.contains(text, "M106 S128\n"))
	testing.expect(t, strings.contains(text, "G4 P2\n"))
	testing.expect(t, strings.contains(text, "M104 S0\nM140 S0\nM84\n"))
	testing.expect_value(t, result.motion_operation_count, u64(6))
	testing.expect_value(t, result.positive_filament_nm, u128(1_000_000))
	testing.expect_value(t, result.negative_filament_nm, u128(1_600_000))
	testing.expect_value(t, result.shutdown_retraction_nm, u64(800_000))
	testing.expect_value(t, result.emitted_dwell_ms, u64(2))
	testing.expect_value(t, result.final_x, contracts.Micrometres(0))
	testing.expect_value(t, result.final_y, contracts.Micrometres(220_000))
	testing.expect_value(t, result.final_z, contracts.Micrometres(10_200))
	testing.expect(t, len(result.commands) > len(motion.operations))
	marlin_expect_command_records_cover_bytes(t, result)
}

@(test)
marlin_rejects_unrepresentable_filament_delta_test :: proc(t: ^testing.T) {
	profile := marlin_test_profile(t)
	motion := marlin_test_motion()
	defer features.motion_plan_result_destroy(&motion)
	motion.operations[0].filament_delta_nm += 1
	result, error := marlin_emit(motion, profile)
	defer marlin_result_destroy(&result)
	testing.expect_value(t, error, Marlin_Error.Invalid_Motion)
}

@(test)
marlin_rejects_park_lift_beyond_machine_bounds_test :: proc(t: ^testing.T) {
	profile := marlin_test_profile(t)
	profile.printer.park_z_lift =
		profile.printer.axis_maximum_z
	motion := marlin_test_motion()
	defer features.motion_plan_result_destroy(&motion)
	result, error := marlin_emit(motion, profile)
	defer marlin_result_destroy(&result)
	testing.expect_value(t, error, Marlin_Error.Invalid_Motion)
}

@(test)
marlin_validator_replays_emitted_state_independently_test :: proc(
	t: ^testing.T,
) {
	profile := marlin_test_profile(t)
	motion := marlin_test_motion()
	defer features.motion_plan_result_destroy(&motion)
	result, emit_error := marlin_emit(motion, profile)
	defer marlin_result_destroy(&result)
	testing.expect_value(t, emit_error, Marlin_Error.None)
	report, validation_error :=
		marlin_validate(result.bytes, profile, motion)
	testing.expect_value(
		t,
		validation_error,
		Marlin_Validation_Error.None,
	)
	testing.expect_value(
		t,
		report.command_count,
		u64(len(result.commands)),
	)
	testing.expect_value(
		t,
		report.motion_operation_count,
		result.motion_operation_count,
	)
	testing.expect_value(
		t,
		report.positive_filament_nm,
		result.positive_filament_nm,
	)
	testing.expect_value(
		t,
		report.negative_filament_nm,
		result.negative_filament_nm,
	)
	testing.expect_value(t, report.dwell_ms, result.emitted_dwell_ms)
	testing.expect_value(t, report.final_x, result.final_x)
	testing.expect_value(t, report.final_y, result.final_y)
	testing.expect_value(t, report.final_z, result.final_z)
}

@(test)
marlin_validator_rejects_injected_mode_change_test :: proc(t: ^testing.T) {
	profile := marlin_test_profile(t)
	motion := marlin_test_motion()
	defer features.motion_plan_result_destroy(&motion)
	result, emit_error := marlin_emit(motion, profile)
	defer marlin_result_destroy(&result)
	testing.expect_value(t, emit_error, Marlin_Error.None)
	mutated := make([]u8, len(result.bytes))
	defer delete(mutated)
	copy(mutated, result.bytes)
	mode_text := "M83\n"
	mode_offset, mode_found :=
		marlin_test_find_bytes(mutated, transmute([]u8)mode_text)
	testing.expect(t, mode_found)
	mutated[mode_offset+2] = '2'
	_, validation_error := marlin_validate(mutated, profile, motion)
	testing.expect(
		t,
		validation_error != Marlin_Validation_Error.None,
	)
}

@(test)
marlin_hash_binds_bytes_records_profiles_and_motion_test :: proc(
	t: ^testing.T,
) {
	profile := marlin_test_profile(t)
	motion := marlin_test_motion()
	defer features.motion_plan_result_destroy(&motion)
	result, emit_error := marlin_emit(motion, profile)
	defer marlin_result_destroy(&result)
	testing.expect_value(t, emit_error, Marlin_Error.None)
	hash, hash_ok := marlin_result_hash({}, motion, profile, result)
	testing.expect(t, hash_ok)
	expected := contracts.Content_Hash{
		0x4b, 0x37, 0xb7, 0x60, 0x43, 0xbc, 0x77, 0xfc,
		0xa4, 0x14, 0x27, 0xf4, 0xc8, 0x5f, 0x7f, 0x2b,
		0x88, 0x7a, 0xc2, 0x09, 0x7c, 0xcd, 0x0e, 0xbf,
		0xb7, 0x86, 0x18, 0x92, 0xd1, 0xb7, 0x45, 0xcb,
	}
	testing.expect_value(t, hash, expected)
	result.bytes[0] = 'X'
	_, mutated_ok := marlin_result_hash({}, motion, profile, result)
	testing.expect(t, !mutated_ok)
}

marlin_expect_command_records_cover_bytes :: proc(
	t: ^testing.T,
	result: Marlin_Result,
) {
	expected_offset: u64
	for command, command_index in result.commands {
		testing.expect_value(t, command.command_index, u32(command_index))
		testing.expect_value(t, command.byte_offset, expected_offset)
		testing.expect(t, command.byte_count > 0)
		end := command.byte_offset+u64(command.byte_count)
		testing.expect(t, end <= u64(len(result.bytes)))
		testing.expect_value(t, result.bytes[end-1], u8('\n'))
		expected_offset = end
	}
	testing.expect_value(t, expected_offset, u64(len(result.bytes)))
}

marlin_test_find_bytes :: proc(
	haystack, needle: []u8,
) -> (int, bool) {
	if len(needle) == 0 || len(needle) > len(haystack) {
		return 0, false
	}
	for offset in 0..=len(haystack)-len(needle) {
		if marlin_test_bytes_equal(
			haystack[offset:offset+len(needle)],
			needle,
		) {
			return offset, true
		}
	}
	return 0, false
}

marlin_test_bytes_equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) {return false}
	for value, index in a {
		if value != b[index] {return false}
	}
	return true
}

marlin_test_motion :: proc() -> features.Motion_Plan_Result {
	result := features.Motion_Plan_Result{
		layers = make([]features.Motion_Layer, 1),
		operations = make([]features.Motion_Operation, 6),
		retraction_count = 1,
		travel_count = 1,
		extrusion_count = 2,
		dwell_count = 1,
		total_motion_duration_us = 73_525,
		total_dwell_duration_us = 1_001,
		total_planned_duration_us = 74_526,
	}
	result.layers[0] = {
		stable_id = 10,
		z = 200,
		operation_count = 6,
		speed_scale_ppm = profiles.RATIO_SCALE,
		base_duration_us = 73_525,
		motion_duration_us = 73_525,
		dwell_duration_us = 1_001,
		planned_duration_us = 74_526,
	}
	result.operations[0] = {
		stable_id = 100,
		source_move_id = 20,
		path_id = 30,
		kind = .Extrude,
		role = .Perimeter,
		point_a = {100, 100},
		point_b = {200, 100},
		speed = 10_000,
		acceleration = 1_000_000,
		fan_ratio = profiles.Ratio_Ppm(500_000),
		filament_delta_nm = 100_000,
		duration_us = 10_000,
	}
	result.operations[1] = {
		stable_id = 101,
		source_move_id = 21,
		source_move_index = 1,
		path_id = 31,
		kind = .Retract,
		point_a = {200, 100},
		point_b = {200, 100},
		speed = 35_000,
		acceleration = 1_000_000,
		filament_delta_nm = -800_000,
		duration_us = 22_858,
		crosses_exterior = true,
	}
	result.operations[2] = {
		stable_id = 102,
		source_move_id = 21,
		source_move_index = 1,
		path_id = 31,
		kind = .Travel,
		point_a = {200, 100},
		point_b = {800, 100},
		speed = 150_000,
		acceleration = 2_000_000,
		duration_us = 4_000,
		crosses_exterior = true,
	}
	result.operations[3] = {
		stable_id = 103,
		source_move_id = 21,
		source_move_index = 1,
		path_id = 31,
		kind = .Recover,
		point_a = {800, 100},
		point_b = {800, 100},
		speed = 30_000,
		acceleration = 1_000_000,
		filament_delta_nm = 800_000,
		duration_us = 26_667,
		crosses_exterior = true,
	}
	result.operations[4] = {
		stable_id = 104,
		source_move_id = 22,
		source_move_index = 2,
		path_id = 32,
		kind = .Extrude,
		role = .Perimeter,
		point_a = {800, 100},
		point_b = {900, 100},
		speed = 10_000,
		acceleration = 1_000_000,
		fan_ratio = profiles.Ratio_Ppm(500_000),
		filament_delta_nm = 100_000,
		duration_us = 10_000,
	}
	result.operations[5] = {
		stable_id = 105,
		layer_index = 0,
		kind = .Dwell,
		point_a = {900, 100},
		point_b = {900, 100},
		duration_us = 1_001,
	}
	return result
}

marlin_test_profile :: proc(t: ^testing.T) -> profiles.Resolved_Profiles {
	role := profiles.Role_Target{
		speed = 40_000,
		acceleration = 1_000_000,
		flow_ratio = profiles.Ratio_Ppm(profiles.RATIO_SCALE),
		fan_ratio = profiles.Ratio_Ppm(500_000),
	}
	printer := profiles.Printer_Profile{
		schema_version = profiles.PRINTER_PROFILE_SCHEMA_VERSION,
		axis_minimum_x = 0,
		axis_maximum_x = 220_000,
		axis_minimum_y = 0,
		axis_maximum_y = 220_000,
		axis_minimum_z = 0,
		axis_maximum_z = 250_000,
		extruder_count = 1,
		nozzle_diameter = 400,
		minimum_layer_height = 80,
		maximum_layer_height = 320,
		minimum_line_width = 200,
		maximum_line_width = 800,
		maximum_speed = 300_000,
		maximum_acceleration = 5_000_000,
		maximum_extruder_speed = 50_000,
		maximum_extruder_acceleration = 5_000_000,
		bed_leveling = .Restore_Stored_Mesh,
		park_after_print = true,
		park_x = 0,
		park_y = 220_000,
		park_z_lift = 10_000,
	}
	material := profiles.Material_Profile{
		schema_version = profiles.MATERIAL_PROFILE_SCHEMA_VERSION,
		filament_diameter = 1_750,
		density = 1_240,
		minimum_nozzle_temperature = 180,
		maximum_nozzle_temperature = 230,
		minimum_bed_temperature = 0,
		maximum_bed_temperature = 70,
		minimum_fan_ratio = 0,
		maximum_fan_ratio = profiles.Ratio_Ppm(profiles.RATIO_SCALE),
		maximum_volumetric_flow = 12_000_000_000,
	}
	process := profiles.Process_Profile{
		schema_version = profiles.PROCESS_PROFILE_SCHEMA_VERSION,
		first_layer_height = 240,
		layer_height = 200,
		minimum_adaptive_height = 120,
		maximum_adaptive_height = 280,
		perimeter_count = 3,
		nominal_line_width = 450,
		top_skin = {800, 3},
		bottom_skin = {800, 3},
		solid_infill_spacing = 450,
		solid_infill_base_angle = 45_000,
		solid_infill_angle_step = 90_000,
		role_overlap = .Subtract_Higher_Priority,
		thin_wall_minimum_ratio = 600_000,
		thin_wall_maximum_ratio = 1_300_000,
		thin_wall_remainder = .Preserve_Unprinted,
		gap_allocation = .One_Then_Two_Lines,
		maximum_centerline_deviation = 100,
		bridge_geometry = .Previous_Layer_Expanded_Support,
		bridge_anchor_margin = 200,
		bridge_direction = .Bounded_Candidate_Score,
		bridge_angle_count = 4,
		bridge_angles = {
			0,
			45_000,
			90_000,
			135_000,
			0,
			0,
			0,
			0,
		},
		minimum_bridge_area = 1_000_000,
		support_demand = .Mesh_And_Layer_Projection,
		support_mode = .Everywhere,
		support_overhang_angle = 45_000,
		support_clearance_xy = 300,
		support_clearance_z = 200,
		support_expansion = 200,
		support_density = 150_000,
		support_pattern = .Rectilinear,
		support_interface_layers = 3,
		support_interface_spacing = 250,
		perimeter = role,
		skin = role,
		sparse_infill = role,
		gap = role,
		bridge = {
			speed = 25_000,
			acceleration = 500_000,
			flow_ratio = 900_000,
			fan_ratio = profiles.Ratio_Ppm(profiles.RATIO_SCALE),
		},
		support = role,
		support_interface = role,
		travel = {150_000, 2_000_000},
		nozzle_temperature = 210,
		bed_temperature = 60,
		minimum_layer_time = 5_000,
		minimum_layer_time_policy = .Slowdown_Then_Dwell,
		minimum_print_speed = 10_000,
		seam = .Deterministic_Cost,
		seam_visibility = .Rear_Maximum_Y,
		retraction = .Distance_And_Exterior_Crossing,
		retraction_distance = 800,
		minimum_retraction_travel = 1_500,
		retraction_speed = 35_000,
		recovery_speed = 30_000,
		retraction_acceleration = 1_000_000,
		travel_policy = .Direct,
		extrusion_accumulation = .Volume_Then_Fixed_Point_Length,
		extrusion_length_quantum_nm = 10,
	}
	dialect := profiles.Dialect_Profile{
		schema_version = profiles.DIALECT_PROFILE_SCHEMA_VERSION,
		dialect = .Marlin_Conservative,
		coordinate_mode = .Absolute,
		extrusion_mode = .Relative,
		xy_decimal_places = 3,
		z_decimal_places = 3,
		e_decimal_places = 5,
		feed_decimal_places = 0,
		line_ending = .LF,
		acceleration_commands = .Profile_Approved,
		output_mode = .File,
		emit_layer_comments = true,
	}
	resolved, error := profiles.profiles_resolve(
		printer,
		material,
		process,
		dialect,
	)
	testing.expect_value(t, error, profiles.Profile_Resolve_Error.None)
	return resolved
}
