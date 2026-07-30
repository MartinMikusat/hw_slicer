package features

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import slicing "../slicing"

@(test)
skins_propagate_until_thickness_and_minimum_layers_are_met_test :: proc(
	t: ^testing.T,
) {
	layer_heights := [?]contracts.Micrometres{300, 200, 200, 200, 200}
	topology, regions, surfaces := skin_test_plate(t, len(layer_heights))
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer surface_result_destroy(&surfaces)
	result, error := skins_propagate(
		topology,
		regions,
		surfaces,
		layer_heights[:],
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			top = {400, 2},
			bottom = {400, 2},
		},
	)
	defer skin_result_destroy(&result)
	testing.expect_value(t, error, Skin_Error.None)
	testing.expect_value(t, len(result.layers), 5)
	testing.expect_value(t, len(result.masks), 4)
	testing.expect_value(t, result.bottom_mask_count, u64(2))
	testing.expect_value(t, result.top_mask_count, u64(2))
	testing.expect_value(t, result.top_bottom_mask_count, u64(0))
	expected_counts := [?]u32{1, 1, 0, 1, 1}
	expected_kinds := [?]Skin_Kind{
		.Bottom,
		.Bottom,
		.Top,
		.Top,
	}
	for expected, layer_index in expected_counts {
		testing.expect_value(
			t,
			result.layers[layer_index].mask_count,
			expected,
		)
	}
	for expected, mask_index in expected_kinds {
		testing.expect_value(t, result.masks[mask_index].kind, expected)
		testing.expect_value(
			t,
			result.masks[mask_index].source_reference_count,
			u32(1),
		)
		testing.expect_value(
			t,
			skin_test_mask_area_2(result, mask_index),
			i128(2_000_000),
		)
	}
}

@(test)
skins_emit_one_combined_role_for_a_thin_plate_test :: proc(t: ^testing.T) {
	layer_heights := [?]contracts.Micrometres{200, 200, 200}
	topology, regions, surfaces := skin_test_plate(t, len(layer_heights))
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer surface_result_destroy(&surfaces)
	result, error := skins_propagate(
		topology,
		regions,
		surfaces,
		layer_heights[:],
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			top = {600, 3},
			bottom = {600, 3},
		},
	)
	defer skin_result_destroy(&result)
	testing.expect_value(t, error, Skin_Error.None)
	testing.expect_value(t, len(result.masks), 3)
	testing.expect_value(t, result.bottom_mask_count, u64(0))
	testing.expect_value(t, result.top_mask_count, u64(0))
	testing.expect_value(t, result.top_bottom_mask_count, u64(3))
	for mask in result.masks {
		testing.expect_value(t, mask.kind, Skin_Kind.Top_Bottom)
		testing.expect_value(t, mask.source_reference_count, u32(2))
		references := result.source_references[
			int(mask.source_reference_offset):
			int(mask.source_reference_offset)+
				int(mask.source_reference_count)
		]
		testing.expect_value(
			t,
			references[0].surface_kind,
			Surface_Kind.Bottom_Exposed,
		)
		testing.expect_value(
			t,
			references[1].surface_kind,
			Surface_Kind.Top_Exposed,
		)
	}
	region_hash, region_hash_ok := slicing.region_result_hash(
		{},
		topology,
		regions,
	)
	surface_hash, surface_hash_ok := surface_result_hash(
		region_hash,
		surfaces,
	)
	schedule_hash: contracts.Content_Hash
	schedule_hash[0] = 0x53
	hash, hash_ok := skin_result_hash(
		surface_hash,
		schedule_hash,
		layer_heights[:],
		regions,
		surfaces,
		result,
	)
	testing.expect(t, region_hash_ok)
	testing.expect(t, surface_hash_ok)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0x9d, 0xc4, 0x87, 0xe6, 0xe4, 0x33, 0x59, 0xde,
		0x91, 0x9e, 0x73, 0x56, 0x54, 0x45, 0x62, 0xa1,
		0x33, 0x1d, 0xf6, 0xfd, 0x6d, 0xd4, 0x21, 0x61,
		0x47, 0x31, 0x19, 0x94, 0x11, 0xde, 0x3f, 0xd9,
	}
	testing.expect_value(t, hash, expected_hash)
}

@(test)
skins_enforce_minimum_layers_after_reaching_physical_thickness_test :: proc(
	t: ^testing.T,
) {
	layer_heights := [?]contracts.Micrometres{500, 500, 500, 500}
	topology, regions, surfaces := skin_test_plate(t, len(layer_heights))
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer surface_result_destroy(&surfaces)
	result, error := skins_propagate(
		topology,
		regions,
		surfaces,
		layer_heights[:],
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			top = {200, 3},
			bottom = {200, 3},
		},
	)
	defer skin_result_destroy(&result)
	testing.expect_value(t, error, Skin_Error.None)
	expected := [?]Skin_Kind{
		.Bottom,
		.Top_Bottom,
		.Top_Bottom,
		.Top,
	}
	testing.expect_value(t, len(result.masks), len(expected))
	for kind, mask_index in expected {
		testing.expect_value(t, result.masks[mask_index].kind, kind)
	}
}

@(test)
skins_reject_invalid_height_and_output_limit_inputs_test :: proc(
	t: ^testing.T,
) {
	layer_heights := [?]contracts.Micrometres{200}
	topology, regions, surfaces := skin_test_plate(t, len(layer_heights))
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer surface_result_destroy(&surfaces)
	config := Skin_Config{
		fill_rule = .Even_Odd,
		top = {200, 1},
		bottom = {200, 1},
	}
	layer_heights[0] = 0
	invalid_result, invalid_error := skins_propagate(
		topology,
		regions,
		surfaces,
		layer_heights[:],
		polygon.CLIPPER2_PROVIDER,
		config,
	)
	defer skin_result_destroy(&invalid_result)
	testing.expect_value(t, invalid_error, Skin_Error.Invalid_Input)

	layer_heights[0] = 200
	limited_result, limited_error := skins_propagate(
		topology,
		regions,
		surfaces,
		layer_heights[:],
		polygon.CLIPPER2_PROVIDER,
		config,
		{
			max_masks = 0,
			max_paths = 10,
			max_points = 100,
			max_source_references = 10,
			polygon = polygon.DEFAULT_POLYGON_LIMITS,
		},
	)
	defer skin_result_destroy(&limited_result)
	testing.expect_value(t, limited_error, Skin_Error.Mask_Limit)
}

@(test)
skin_hash_rejects_mutated_source_provenance_test :: proc(t: ^testing.T) {
	layer_heights := [?]contracts.Micrometres{200}
	topology, regions, surfaces := skin_test_plate(t, len(layer_heights))
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer surface_result_destroy(&surfaces)
	result, error := skins_propagate(
		topology,
		regions,
		surfaces,
		layer_heights[:],
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			top = {200, 1},
			bottom = {200, 1},
		},
	)
	defer skin_result_destroy(&result)
	testing.expect_value(t, error, Skin_Error.None)
	if len(result.source_references) == 0 {return}
	result.source_references[0].source_layer_index += 1
	_, hash_ok := skin_result_hash(
		{},
		{},
		layer_heights[:],
		regions,
		surfaces,
		result,
	)
	testing.expect(t, !hash_ok)
}

skin_test_plate :: proc(
	t: ^testing.T,
	layer_count: int,
) -> (
	slicing.Topology_Result,
	slicing.Region_Result,
	Surface_Result,
) {
	path_counts := make([]u32, layer_count)
	path_points := make([][4]slicing.Snapped_Point, layer_count)
	for &count in path_counts {
		count = 1
	}
	for &points in path_points {
		points = {
			{0, 0},
			{1_000, 0},
			{1_000, 1_000},
			{0, 1_000},
		}
	}
	topology := surface_rect_topology(path_counts, path_points)
	delete(path_counts)
	delete(path_points)
	regions, region_error := slicing.regions_build(topology)
	surfaces, surface_error := surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Strict_Printable,
		},
	)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	testing.expect_value(t, surface_error, Surface_Error.None)
	return topology, regions, surfaces
}

skin_test_mask_area_2 :: proc(result: Skin_Result, mask_index: int) -> i128 {
	mask := result.masks[mask_index]
	area: i128
	start := int(mask.path_offset)
	end := start+int(mask.path_count)
	for path in result.paths[start:end] {
		area += path.signed_area_2
	}
	return area
}
