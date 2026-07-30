package features

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"

@(test)
extrusion_accumulates_rounded_bead_volume_and_filament_test :: proc(
	t: ^testing.T,
) {
	plan := extrusion_test_plan(t, 400)
	defer unified_path_plan_result_destroy(&plan)
	process := extrusion_test_process(10)
	material := profiles.Material_Profile{filament_diameter = 1_750}
	result, error := extrusion_calculate(
		plan,
		[]contracts.Micrometres{200},
		material,
		process,
	)
	defer extrusion_result_destroy(&result)
	testing.expect_value(t, error, Extrusion_Error.None)
	testing.expect_value(
		t,
		result.cross_section_model,
		Extrusion_Cross_Section_Model.Rounded_Bead,
	)
	testing.expect_value(t, result.pi_scale, EXTRUSION_PI_SCALE)
	testing.expect_value(t, result.pi_scaled, EXTRUSION_PI_SCALED)
	testing.expect_value(t, result.length_quantum_nm, u32(10))
	testing.expect_value(t, len(result.moves), 2)
	testing.expect_value(t, result.layers[0].move_count, u32(2))
	for move in result.moves {
		testing.expect_value(t, move.path_length_nm, u64(10_000_000))
		testing.expect_value(t, move.distance_squared_um_2, u128(100_000_000))
		testing.expect_value(t, move.length_error_squared_nm_2, u128(0))
		testing.expect_value(t, move.layer_height, contracts.Micrometres(200))
		testing.expect_value(t, move.line_width_a, contracts.Micrometres(400))
		testing.expect_value(t, move.line_width_b, contracts.Micrometres(400))
		testing.expect_value(t, move.flow_ratio, profiles.Ratio_Ppm(1_000_000))
		testing.expect_value(t, move.volume_cubic_um, u64(714_159_265))
		testing.expect_value(
			t,
			move.incremental_filament_nm%u64(result.length_quantum_nm),
			u64(0),
		)
	}
	sum_numerator := result.moves[0].volume_numerator+
		result.moves[1].volume_numerator
	testing.expect_value(t, result.total_volume_numerator, sum_numerator)
	testing.expect_value(
		t,
		result.total_volume_cubic_um,
		u64(1_428_318_531),
	)
	testing.expect_value(
		t,
		result.total_filament_nm*
			result.filament_length_denominator+
			result.final_remainder_numerator,
		sum_numerator,
	)
	testing.expect(
		t,
		result.final_remainder_numerator <
			result.quantized_length_denominator,
	)
}

@(test)
extrusion_integer_sqrt_rounds_to_nearest_nanometre_test :: proc(
	t: ^testing.T,
) {
	exact, exact_error, exact_ok :=
		extrusion_integer_sqrt_round(25_000_000)
	testing.expect(t, exact_ok)
	testing.expect_value(t, exact, u64(5_000))
	testing.expect_value(t, exact_error, u128(0))
	rounded, rounded_error, rounded_ok :=
		extrusion_integer_sqrt_round(2_000_000)
	testing.expect(t, rounded_ok)
	testing.expect_value(t, rounded, u64(1_414))
	testing.expect_value(
		t,
		rounded_error,
		u128(2_000_000)-u128(1_414)*u128(1_414),
	)
}

@(test)
extrusion_rejects_line_width_below_layer_height_test :: proc(
	t: ^testing.T,
) {
	plan := extrusion_test_plan(t, 100)
	defer unified_path_plan_result_destroy(&plan)
	result, error := extrusion_calculate(
		plan,
		[]contracts.Micrometres{200},
		profiles.Material_Profile{filament_diameter = 1_750},
		extrusion_test_process(1),
	)
	defer extrusion_result_destroy(&result)
	testing.expect_value(t, error, Extrusion_Error.Invalid_Input)
}

@(test)
extrusion_hash_rejects_mutated_filament_increment_test :: proc(
	t: ^testing.T,
) {
	plan := extrusion_test_plan(t, 400)
	defer unified_path_plan_result_destroy(&plan)
	process := extrusion_test_process(1)
	material := profiles.Material_Profile{filament_diameter = 1_750}
	heights := []contracts.Micrometres{200}
	result, error := extrusion_calculate(
		plan,
		heights,
		material,
		process,
	)
	defer extrusion_result_destroy(&result)
	testing.expect_value(t, error, Extrusion_Error.None)
	hash, hash_ok := extrusion_result_hash(
		{},
		{},
		{},
		{},
		plan,
		heights,
		material,
		process,
		result,
	)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0x85, 0x16, 0x56, 0x82, 0xa4, 0x30, 0xde, 0xa5,
		0x6d, 0x15, 0xb9, 0x4a, 0xdd, 0xfb, 0xf9, 0xbe,
		0xed, 0xc7, 0x47, 0x3d, 0x8a, 0x88, 0x2a, 0x28,
		0x0a, 0xc5, 0xf9, 0x18, 0x27, 0x46, 0x39, 0x2e,
	}
	testing.expect_value(t, hash, expected_hash)
	replayed_hash, replayed_hash_ok :=
		extrusion_result_content_hash({}, result)
	testing.expect(t, replayed_hash_ok)
	testing.expect_value(t, replayed_hash, hash)
	result.moves[0].incremental_filament_nm += 1
	_, mutated_hash_ok := extrusion_result_hash(
		{},
		{},
		{},
		{},
		plan,
		heights,
		material,
		process,
		result,
	)
	testing.expect(t, !mutated_hash_ok)
	_, mutated_content_hash_ok :=
		extrusion_result_content_hash({}, result)
	testing.expect(t, !mutated_content_hash_ok)
}

extrusion_test_plan :: proc(
	t: ^testing.T,
	width: contracts.Micrometres,
) -> Unified_Path_Plan_Result {
	sources := make([]Unified_Path_Source, 2)
	for &source, source_index in sources {
		source.stable_id = contracts.Stable_ID(100+source_index)
		source.layer_id = 10
		source.role = .Perimeter
		source.source_kind = .Perimeter
		source.source_index = u32(source_index)
		source.source_order = u64(source_index)
		source.points = make([]polygon.Polygon_Point, 2)
		source.line_widths = make([]contracts.Micrometres, 2)
		source.points[0] = {
			contracts.Micrometres(source_index*10_000),
			0,
		}
		source.points[1] = {
			contracts.Micrometres((source_index+1)*10_000),
			0,
		}
		source.line_widths[0] = width
		source.line_widths[1] = width
	}
	result, error := unified_path_plan_build(
		[]contracts.Stable_ID{10},
		sources,
		unified_path_plan_test_config(),
	)
	for &source in sources {
		delete(source.points)
		delete(source.line_widths)
	}
	delete(sources)
	testing.expect_value(t, error, Unified_Path_Plan_Error.None)
	return result
}

extrusion_test_process :: proc(
	quantum_nm: u32,
) -> profiles.Resolved_Process_Profile {
	return {
		source = {
			extrusion_accumulation = .Volume_Then_Fixed_Point_Length,
			extrusion_length_quantum_nm = quantum_nm,
			perimeter = {
				flow_ratio =
					profiles.Ratio_Ppm(profiles.RATIO_SCALE),
			},
		},
	}
}
