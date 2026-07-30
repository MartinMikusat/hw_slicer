package features

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"

@(test)
motion_plan_retracts_for_exterior_travel_and_scales_short_layer_test :: proc(
	t: ^testing.T,
) {
	layer_ids, layer_z, model, plan, extrusion, profile :=
		motion_plan_test_inputs(t, true, 100)
	defer motion_plan_test_inputs_destroy(
		layer_ids,
		layer_z,
		model,
		&plan,
		&extrusion,
	)
	testing.expect_value(t, layer_ids[0], contracts.Stable_ID(10))
	testing.expect_value(t, layer_z[0], contracts.Micrometres(200))
	testing.expect_value(
		t,
		profile.printer.axis_minimum_z,
		contracts.Micrometres(0),
	)
	testing.expect_value(
		t,
		profile.printer.axis_maximum_z,
		contracts.Micrometres(1_000),
	)
	result, error := motion_plan_build(
		layer_ids,
		layer_z,
		model,
		plan,
		extrusion,
		profile,
	)
	defer motion_plan_result_destroy(&result)
	testing.expect_value(t, error, Motion_Plan_Error.None)
	testing.expect_value(t, result.retraction_count, u64(1))
	testing.expect_value(t, result.travel_count, u64(1))
	testing.expect_value(t, result.extrusion_count, u64(2))
	testing.expect_value(t, result.dwell_count, u64(0))
	testing.expect_value(t, len(result.operations), 5)
	testing.expect_value(t, result.operations[0].kind, Motion_Operation_Kind.Extrude)
	testing.expect_value(t, result.operations[1].kind, Motion_Operation_Kind.Retract)
	testing.expect_value(t, result.operations[2].kind, Motion_Operation_Kind.Travel)
	testing.expect_value(t, result.operations[3].kind, Motion_Operation_Kind.Recover)
	testing.expect_value(t, result.operations[4].kind, Motion_Operation_Kind.Extrude)
	testing.expect(t, result.operations[2].crosses_exterior)
	testing.expect_value(
		t,
		result.operations[1].filament_delta_nm,
		i128(-800_000),
	)
	testing.expect_value(
		t,
		result.operations[3].filament_delta_nm,
		i128(800_000),
	)
	testing.expect(t, result.layers[0].speed_scale_ppm > 0)
	testing.expect(
		t,
		result.layers[0].speed_scale_ppm < profiles.RATIO_SCALE,
	)
	testing.expect(
		t,
		result.layers[0].planned_duration_us >= 100_000,
	)
}

@(test)
motion_plan_uses_residual_dwell_after_minimum_print_speed_test :: proc(
	t: ^testing.T,
) {
	layer_ids, layer_z, model, plan, extrusion, profile :=
		motion_plan_test_inputs(t, true, 1_000)
	defer motion_plan_test_inputs_destroy(
		layer_ids,
		layer_z,
		model,
		&plan,
		&extrusion,
	)
	result, error := motion_plan_build(
		layer_ids,
		layer_z,
		model,
		plan,
		extrusion,
		profile,
	)
	defer motion_plan_result_destroy(&result)
	testing.expect_value(t, error, Motion_Plan_Error.None)
	testing.expect_value(t, result.layers[0].speed_scale_ppm, u32(0))
	testing.expect(t, result.layers[0].dwell_duration_us > 0)
	testing.expect_value(t, result.dwell_count, u64(1))
	testing.expect_value(
		t,
		result.layers[0].planned_duration_us,
		u64(1_000_000),
	)
	testing.expect_value(
		t,
		result.operations[len(result.operations)-1].kind,
		Motion_Operation_Kind.Dwell,
	)
}

@(test)
motion_plan_does_not_retract_for_contained_travel_test :: proc(
	t: ^testing.T,
) {
	layer_ids, layer_z, model, plan, extrusion, profile :=
		motion_plan_test_inputs(t, false, 1)
	defer motion_plan_test_inputs_destroy(
		layer_ids,
		layer_z,
		model,
		&plan,
		&extrusion,
	)
	result, error := motion_plan_build(
		layer_ids,
		layer_z,
		model,
		plan,
		extrusion,
		profile,
	)
	defer motion_plan_result_destroy(&result)
	testing.expect_value(t, error, Motion_Plan_Error.None)
	testing.expect_value(t, result.retraction_count, u64(0))
	testing.expect_value(t, len(result.operations), 3)
	testing.expect(t, !result.operations[1].crosses_exterior)
}

@(test)
motion_plan_detects_an_off_midpoint_hole_crossing_test :: proc(
	t: ^testing.T,
) {
	model := motion_plan_test_model(true, 100, 200)
	defer polygon.polygon_set_destroy(&model)
	testing.expect(
		t,
		motion_travel_crosses_exterior(
			{50, 500},
			{950, 500},
			model,
		),
	)
}

@(test)
motion_plan_does_not_cool_an_empty_layer_test :: proc(t: ^testing.T) {
	layer_ids := []contracts.Stable_ID{10}
	layer_z := []contracts.Micrometres{200}
	model := []polygon.Polygon_Set{{}}
	plan := Unified_Path_Plan_Result{
		config = {
			start = {100, 500},
			seam = .Deterministic_Cost,
			seam_visibility = .Rear_Maximum_Y,
		},
		layers = []Unified_Planned_Layer{{}},
	}
	extrusion := Extrusion_Result{
		layers = []Extrusion_Layer{{}},
	}
	profile := motion_plan_test_profile(1_000)
	result, error := motion_plan_build(
		layer_ids,
		layer_z,
		model,
		plan,
		extrusion,
		profile,
	)
	defer motion_plan_result_destroy(&result)
	testing.expect_value(t, error, Motion_Plan_Error.None)
	testing.expect_value(t, len(result.operations), 0)
	testing.expect_value(t, result.layers[0].planned_duration_us, u64(0))
	testing.expect_value(
		t,
		result.layers[0].speed_scale_ppm,
		profiles.RATIO_SCALE,
	)
}

@(test)
motion_plan_hash_rejects_mutated_operation_test :: proc(t: ^testing.T) {
	layer_ids, layer_z, model, plan, extrusion, profile :=
		motion_plan_test_inputs(t, true, 100)
	defer motion_plan_test_inputs_destroy(
		layer_ids,
		layer_z,
		model,
		&plan,
		&extrusion,
	)
	result, error := motion_plan_build(
		layer_ids,
		layer_z,
		model,
		plan,
		extrusion,
		profile,
	)
	defer motion_plan_result_destroy(&result)
	testing.expect_value(t, error, Motion_Plan_Error.None)
	hash, hash_ok := motion_plan_result_hash(
		{},
		{},
		layer_ids,
		layer_z,
		model,
		plan,
		extrusion,
		profile,
		result,
	)
	testing.expect(t, hash_ok)
	expected := contracts.Content_Hash{
		0xc1, 0x75, 0x34, 0x87, 0xc8, 0x1f, 0x32, 0xe4,
		0xe4, 0x41, 0xec, 0xf8, 0xf0, 0x48, 0x7d, 0x50,
		0x29, 0x6d, 0x1d, 0x3a, 0xc5, 0x63, 0x15, 0x12,
		0x4f, 0xc3, 0x9e, 0xd0, 0xbd, 0x9d, 0xf0, 0x94,
	}
	testing.expect_value(t, hash, expected)
	result.operations[0].duration_us += 1
	_, mutated_ok := motion_plan_result_hash(
		{},
		{},
		layer_ids,
		layer_z,
		model,
		plan,
		extrusion,
		profile,
		result,
	)
	testing.expect(t, !mutated_ok)
}

motion_plan_test_inputs :: proc(
	t: ^testing.T,
	with_hole: bool,
	minimum_layer_time_ms: u32,
) -> (
	[]contracts.Stable_ID,
	[]contracts.Micrometres,
	[]polygon.Polygon_Set,
	Unified_Path_Plan_Result,
	Extrusion_Result,
	profiles.Resolved_Profiles,
) {
	layer_ids := make([]contracts.Stable_ID, 1)
	layer_ids[0] = 10
	layer_z := make([]contracts.Micrometres, 1)
	layer_z[0] = 200
	sources := make([]Unified_Path_Source, 2)
	for &source, source_index in sources {
		source = {
			stable_id = contracts.Stable_ID(source_index+1),
			layer_id = 10,
			role = .Perimeter,
			source_kind = .Perimeter,
			source_order = u64(source_index),
		}
		source.points = make([]polygon.Polygon_Point, 2)
		source.line_widths = make([]contracts.Micrometres, 2)
		x := 100+source_index*700
		source.points[0] = {contracts.Micrometres(x), 500}
		source.points[1] = {contracts.Micrometres(x+100), 500}
		source.line_widths[0] = 400
		source.line_widths[1] = 400
	}
	plan, plan_error := unified_path_plan_build(
		layer_ids,
		sources,
		{
			start = {100, 500},
			seam = .Deterministic_Cost,
			seam_visibility = .Rear_Maximum_Y,
		},
	)
	unified_path_plan_test_sources_destroy(sources)
	testing.expect_value(t, plan_error, Unified_Path_Plan_Error.None)
	profile := motion_plan_test_profile(minimum_layer_time_ms)
	extrusion, extrusion_error := extrusion_calculate(
		plan,
		[]contracts.Micrometres{200},
		profile.material,
		profile.process,
	)
	testing.expect_value(t, extrusion_error, Extrusion_Error.None)
	model_set := motion_plan_test_model(with_hole, 400, 600)
	_, model_ok := polygon.polygon_set_hash(model_set)
	testing.expect(t, model_ok)
	testing.expect(t, extrusion_plan_valid(plan))
	testing.expect_value(t, len(extrusion.layers), len(plan.layers))
	testing.expect_value(t, len(extrusion.moves), int(plan.extrude_move_count))
	for extrusion_move in extrusion.moves {
		planned_move := plan.moves[extrusion_move.planned_move_index]
		testing.expect_value(
			t,
			extrusion_move.planned_move_id,
			planned_move.stable_id,
		)
		testing.expect_value(
			t,
			extrusion_move.path_id,
			planned_move.path_id,
		)
		testing.expect_value(t, extrusion_move.layer_index, u32(0))
		testing.expect_value(
			t,
			extrusion_move.role,
			planned_move.role,
		)
		length_nm, length_ok := motion_move_length_nm(
			planned_move.point_a,
			planned_move.point_b,
		)
		testing.expect(t, length_ok)
		testing.expect_value(
			t,
			extrusion_move.path_length_nm,
			length_nm,
		)
	}
	model := make([]polygon.Polygon_Set, 1)
	model[0] = model_set
	return layer_ids, layer_z, model, plan, extrusion, profile
}

motion_plan_test_profile :: proc(
	minimum_layer_time_ms: u32,
) -> profiles.Resolved_Profiles {
	role := profiles.Role_Target{
		speed = 10_000,
		acceleration = 1_000_000,
		flow_ratio = profiles.Ratio_Ppm(profiles.RATIO_SCALE),
		fan_ratio = profiles.Ratio_Ppm(500_000),
	}
	return {
		printer = {
			schema_version = profiles.PRINTER_PROFILE_SCHEMA_VERSION,
			axis_minimum_x = 0,
			axis_maximum_x = 1_000,
			axis_minimum_y = 0,
			axis_maximum_y = 1_000,
			axis_minimum_z = 0,
			axis_maximum_z = 1_000,
			extruder_count = 1,
			nozzle_diameter = 400,
			minimum_layer_height = 100,
			maximum_layer_height = 300,
			minimum_line_width = 200,
			maximum_line_width = 800,
			maximum_speed = 200_000,
			maximum_acceleration = 5_000_000,
			maximum_extruder_speed = 50_000,
			maximum_extruder_acceleration = 5_000_000,
			bed_leveling = .None,
		},
		material = {
			schema_version = profiles.MATERIAL_PROFILE_SCHEMA_VERSION,
			filament_diameter = 1_750,
			density = 1_240,
			minimum_nozzle_temperature = 180,
			maximum_nozzle_temperature = 230,
			minimum_bed_temperature = 0,
			maximum_bed_temperature = 70,
			maximum_fan_ratio =
				profiles.Ratio_Ppm(profiles.RATIO_SCALE),
			maximum_volumetric_flow = 12_000_000_000,
		},
		process = {
			source = {
				perimeter = role,
				skin = role,
				sparse_infill = role,
				gap = role,
				bridge = role,
				support = role,
				support_interface = role,
				travel = {100_000, 2_000_000},
				minimum_layer_time =
					profiles.Duration_Milliseconds(
						minimum_layer_time_ms,
					),
				minimum_layer_time_policy = .Slowdown_Then_Dwell,
				minimum_print_speed = 2_000,
				retraction = .Distance_And_Exterior_Crossing,
				retraction_distance = 800,
				minimum_retraction_travel = 100,
				retraction_speed = 40_000,
				recovery_speed = 40_000,
				retraction_acceleration = 1_000_000,
				travel_policy = .Direct,
				extrusion_accumulation =
					.Volume_Then_Fixed_Point_Length,
				extrusion_length_quantum_nm = 1,
			},
		},
		dialect = {
			schema_version = profiles.DIALECT_PROFILE_SCHEMA_VERSION,
			dialect = .Marlin_Conservative,
			coordinate_mode = .Absolute,
			extrusion_mode = .Relative,
			xy_decimal_places = 3,
			z_decimal_places = 3,
			e_decimal_places = 5,
			line_ending = .LF,
			acceleration_commands = .Profile_Approved,
			output_mode = .File,
			emit_layer_comments = true,
		},
	}
}

motion_plan_test_model :: proc(
	with_hole: bool,
	hole_minimum_x, hole_maximum_x: contracts.Micrometres,
) -> polygon.Polygon_Set {
	path_count := 1
	point_count := 4
	if with_hole {
		path_count = 2
		point_count = 8
	}
	result := polygon.Polygon_Set{
		points = make([]polygon.Polygon_Point, point_count),
		paths = make([]polygon.Polygon_Path, path_count),
	}
	copy(
		result.points[:4],
		[]polygon.Polygon_Point{
			{0, 0},
			{1_000, 0},
			{1_000, 1_000},
			{0, 1_000},
		},
	)
	result.paths[0] = {0, 4}
	if with_hole {
		copy(
			result.points[4:],
			[]polygon.Polygon_Point{
				{hole_minimum_x, 400},
				{hole_maximum_x, 400},
				{hole_maximum_x, 600},
				{hole_minimum_x, 600},
			},
		)
		result.paths[1] = {4, 4}
	}
	return result
}

motion_plan_test_inputs_destroy :: proc(
	layer_ids: []contracts.Stable_ID,
	layer_z: []contracts.Micrometres,
	model: []polygon.Polygon_Set,
	plan: ^Unified_Path_Plan_Result,
	extrusion: ^Extrusion_Result,
) {
	delete(layer_ids)
	delete(layer_z)
	for &set in model {polygon.polygon_set_destroy(&set)}
	delete(model)
	unified_path_plan_result_destroy(plan)
	extrusion_result_destroy(extrusion)
}
