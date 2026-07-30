package features

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import slicing "../slicing"

@(test)
infill_clips_phased_scanlines_against_an_inset_region_test :: proc(
	t: ^testing.T,
) {
	topology := perimeter_test_topology()
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	result, error := infill_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			spacing = 200,
			boundary_inset = 100,
			phase = 0,
			base_axis = .Vertical,
			alternate_each_layer = true,
			join_type = .Miter,
			miter_limit = 2,
			arc_tolerance = 0,
		},
	)
	defer infill_result_destroy(&result)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, error, Infill_Error.None)
	testing.expect_value(t, result.scanline_count, u64(4))
	testing.expect_value(t, len(result.layers), 1)
	testing.expect_value(t, result.layers[0].axis, Infill_Axis.Vertical)
	testing.expect_value(t, len(result.segments), 6)
	testing.expect_value(t, len(result.boundary_hits), 12)
	expected_lines := [?]contracts.Micrometres{
		200,
		400,
		400,
		600,
		600,
		800,
	}
	for segment, index in result.segments {
		testing.expect_value(
			t,
			segment.line_coordinate,
			expected_lines[index],
		)
		testing.expect(t, segment.point_a.y < segment.point_b.y)
		testing.expect_value(t, segment.hit_offset, u64(index*2))
	}
	for hit in result.boundary_hits {
		testing.expect_value(t, hit.error_numerator, u128(0))
		testing.expect(t, hit.denominator > 0)
	}
	region_hash, region_hash_ok := slicing.region_result_hash(
		contracts.Content_Hash{},
		topology,
		regions,
	)
	result_hash, hash_ok := infill_result_hash(region_hash, result)
	testing.expect(t, region_hash_ok)
	testing.expect(t, hash_ok)
	testing.expect(t, result_hash != contracts.Content_Hash{})
}

@(test)
infill_alternates_the_scan_axis_by_layer_test :: proc(t: ^testing.T) {
	config := Infill_Config{
		spacing = 200,
		boundary_inset = 100,
		phase = 0,
		base_axis = .Vertical,
		alternate_each_layer = true,
		join_type = .Miter,
		miter_limit = 2,
	}
	testing.expect_value(
		t,
		infill_layer_axis(config, 0),
		Infill_Axis.Vertical,
	)
	testing.expect_value(
		t,
		infill_layer_axis(config, 1),
		Infill_Axis.Horizontal,
	)
	testing.expect_value(
		t,
		infill_layer_axis(config, 2),
		Infill_Axis.Vertical,
	)
}

@(test)
infill_rejects_invalid_phase_and_scanline_limits_test :: proc(
	t: ^testing.T,
) {
	topology := perimeter_test_topology()
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	invalid_result, invalid_error := infill_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			spacing = 200,
			boundary_inset = 100,
			phase = 200,
			base_axis = .Vertical,
			join_type = .Miter,
			miter_limit = 2,
		},
	)
	defer infill_result_destroy(&invalid_result)
	limited_result, limited_error := infill_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			spacing = 200,
			boundary_inset = 100,
			phase = 0,
			base_axis = .Vertical,
			join_type = .Miter,
			miter_limit = 2,
		},
		{
			max_scanlines = 1,
			max_segments = 100,
			polygon = polygon.DEFAULT_POLYGON_LIMITS,
		},
	)
	defer infill_result_destroy(&limited_result)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, invalid_error, Infill_Error.Invalid_Config)
	testing.expect_value(
		t,
		limited_error,
		Infill_Error.Scanline_Limit,
	)
}

@(test)
infill_hash_rejects_mutated_rational_evidence_test :: proc(
	t: ^testing.T,
) {
	topology := perimeter_test_topology()
	defer slicing.topology_result_destroy(&topology)
	regions, region_error := slicing.regions_build(topology)
	defer slicing.region_result_destroy(&regions)
	result, error := infill_generate(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			spacing = 200,
			boundary_inset = 100,
			phase = 0,
			base_axis = .Vertical,
			join_type = .Miter,
			miter_limit = 2,
		},
	)
	defer infill_result_destroy(&result)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, error, Infill_Error.None)
	if len(result.boundary_hits) == 0 {return}
	result.boundary_hits[0].error_numerator += 1
	_, hash_ok := infill_result_hash(contracts.Content_Hash{}, result)
	testing.expect(t, !hash_ok)
}

@(test)
infill_rational_intersections_round_ties_away_from_zero_test :: proc(
	t: ^testing.T,
) {
	a := polygon.Polygon_Point{-10, -10}
	b := polygon.Polygon_Point{10, 7}
	numerator, denominator, crosses := infill_edge_intersection(
		a,
		b,
		.Vertical,
		0,
	)
	reverse_numerator, reverse_denominator, reverse_crosses :=
		infill_edge_intersection(
			b,
			a,
			.Vertical,
			0,
		)
	rounded, error_numerator, round_ok :=
		infill_rational_round(numerator, denominator)
	testing.expect(t, crosses)
	testing.expect(t, reverse_crosses)
	testing.expect_value(t, numerator, i128(-30))
	testing.expect_value(t, denominator, i128(20))
	testing.expect_value(t, reverse_numerator, numerator)
	testing.expect_value(t, reverse_denominator, denominator)
	testing.expect(t, round_ok)
	testing.expect_value(t, rounded, contracts.Micrometres(-2))
	testing.expect_value(t, error_numerator, u128(10))

	positive, positive_error, positive_ok :=
		infill_rational_round(3, 2)
	negative, negative_error, negative_ok :=
		infill_rational_round(-3, 2)
	testing.expect(t, positive_ok)
	testing.expect(t, negative_ok)
	testing.expect_value(t, positive, contracts.Micrometres(2))
	testing.expect_value(t, negative, contracts.Micrometres(-2))
	testing.expect_value(t, positive_error, u128(1))
	testing.expect_value(t, negative_error, u128(1))
	_, _, minimum_ok := infill_rational_round(min(i128), 1)
	_, _, zero_denominator_ok := infill_rational_round(1, 0)
	testing.expect(t, !minimum_ok)
	testing.expect(t, !zero_denominator_ok)
}

@(test)
infill_scanline_phase_is_strictly_inside_negative_bounds_test :: proc(
	t: ^testing.T,
) {
	line_on_boundary, on_boundary_ok := infill_first_scanline(
		-20,
		0,
		10,
	)
	line_between, between_ok := infill_first_scanline(
		-21,
		0,
		10,
	)
	testing.expect(t, on_boundary_ok)
	testing.expect(t, between_ok)
	testing.expect_value(
		t,
		line_on_boundary,
		contracts.Micrometres(-10),
	)
	testing.expect_value(t, line_between, contracts.Micrometres(-20))
	_, zero_spacing_ok := infill_first_scanline(-20, 0, 0)
	testing.expect(t, !zero_spacing_ok)
}
