package features

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"

@(test)
role_overlap_subtracts_each_higher_priority_role_test :: proc(
	t: ^testing.T,
) {
	layer_ids := []contracts.Stable_ID{10}
	sources := role_overlap_test_sources()
	defer role_overlap_test_sources_destroy(sources)
	result, error := role_overlap_resolve(
		layer_ids,
		sources,
		role_overlap_test_process(),
		polygon.CLIPPER2_PROVIDER,
		.Even_Odd,
	)
	defer role_overlap_result_destroy(&result)
	testing.expect_value(t, error, Role_Overlap_Error.None)
	testing.expect_value(
		t,
		result.policy,
		profiles.Role_Overlap_Policy.Subtract_Higher_Priority,
	)
	testing.expect_value(t, len(result.masks), 5)
	testing.expect_value(t, len(result.paths), 5)
	testing.expect_value(t, result.layers[0].mask_count, u32(5))
	testing.expect_value(t, result.layers[0].path_count, u32(5))
	testing.expect_value(t, result.fully_removed_mask_count, u64(0))
	testing.expect_value(t, result.source_area_2, i128(2_800_000))
	testing.expect_value(t, result.output_area_2, i128(2_000_000))
	testing.expect_value(t, result.removed_area_2, i128(800_000))
	expected_roles := []profiles.Printable_Role{
		.Perimeter,
		.Bridge,
		.Gap,
		.Top_Skin,
		.Sparse_Infill,
	}
	expected_minimum_x := []contracts.Micrometres{
		0,
		200,
		400,
		600,
		800,
	}
	for mask, mask_index in result.masks {
		testing.expect_value(t, mask.role, expected_roles[mask_index])
		testing.expect_value(t, mask.priority, u8(mask_index+1))
		testing.expect_value(t, mask.path_count, u32(1))
		testing.expect_value(t, mask.output_area_2, i128(400_000))
		path := result.paths[mask.path_offset]
		testing.expect_value(t, path.mask_id, mask.stable_id)
		points_start := int(path.point_offset)
		points_end := points_start+int(path.point_count)
		points := result.points[points_start:points_end]
		testing.expect_value(t, len(points), 4)
		testing.expect_value(
			t,
			points[0].x,
			expected_minimum_x[mask_index],
		)
		testing.expect_value(
			t,
			points[2].x,
			expected_minimum_x[mask_index]+200,
		)
	}
}

@(test)
role_overlap_preserves_fully_removed_source_evidence_test :: proc(
	t: ^testing.T,
) {
	layer_ids := []contracts.Stable_ID{10}
	sources := make([]Role_Overlap_Source, 2)
	sources[0] = role_overlap_test_source(1, .Perimeter, 0, 500)
	sources[1] =
		role_overlap_test_source(2, .Sparse_Infill, 100, 400)
	defer role_overlap_test_sources_destroy(sources)
	result, error := role_overlap_resolve(
		layer_ids,
		sources,
		role_overlap_test_process(),
		polygon.CLIPPER2_PROVIDER,
		.Even_Odd,
	)
	defer role_overlap_result_destroy(&result)
	testing.expect_value(t, error, Role_Overlap_Error.None)
	testing.expect_value(t, len(result.masks), 2)
	testing.expect_value(t, len(result.paths), 1)
	testing.expect_value(t, result.fully_removed_mask_count, u64(1))
	testing.expect_value(t, result.masks[1].path_count, u32(0))
	testing.expect_value(t, result.masks[1].output_area_2, i128(0))
	testing.expect_value(
		t,
		result.masks[1].removed_area_2,
		result.masks[1].source_area_2,
	)
}

@(test)
role_overlap_rejects_same_priority_geometry_test :: proc(t: ^testing.T) {
	layer_ids := []contracts.Stable_ID{10}
	sources := make([]Role_Overlap_Source, 2)
	sources[0] = role_overlap_test_source(1, .Top_Skin, 0, 500)
	sources[1] =
		role_overlap_test_source(2, .Bottom_Skin, 250, 750)
	defer role_overlap_test_sources_destroy(sources)
	result, error := role_overlap_resolve(
		layer_ids,
		sources,
		role_overlap_test_process(),
		polygon.CLIPPER2_PROVIDER,
		.Even_Odd,
	)
	defer role_overlap_result_destroy(&result)
	testing.expect_value(
		t,
		error,
		Role_Overlap_Error.Same_Priority_Overlap,
	)
}

@(test)
role_overlap_hash_rejects_mutated_removed_area_test :: proc(t: ^testing.T) {
	layer_ids := []contracts.Stable_ID{10}
	sources := role_overlap_test_sources()
	defer role_overlap_test_sources_destroy(sources)
	process := role_overlap_test_process()
	result, error := role_overlap_resolve(
		layer_ids,
		sources,
		process,
		polygon.CLIPPER2_PROVIDER,
		.Even_Odd,
	)
	defer role_overlap_result_destroy(&result)
	testing.expect_value(t, error, Role_Overlap_Error.None)
	hash, hash_ok := role_overlap_result_hash(
		{},
		{},
		layer_ids,
		sources,
		process,
		polygon.CLIPPER2_PROVIDER,
		result,
	)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0xe2, 0xa3, 0xf8, 0xec, 0xbf, 0xb0, 0x7e, 0x8d,
		0x06, 0x71, 0x02, 0x28, 0x2d, 0x32, 0xd7, 0x52,
		0xbe, 0x60, 0xce, 0x68, 0xa3, 0x65, 0x19, 0xf2,
		0xae, 0x2d, 0xae, 0xf9, 0xce, 0xe7, 0x7a, 0x41,
	}
	testing.expect_value(t, hash, expected_hash)
	result.masks[1].removed_area_2 += 1
	_, mutated_hash_ok := role_overlap_result_hash(
		{},
		{},
		layer_ids,
		sources,
		process,
		polygon.CLIPPER2_PROVIDER,
		result,
	)
	testing.expect(t, !mutated_hash_ok)
}

role_overlap_test_process :: proc() -> profiles.Resolved_Process_Profile {
	return {
		source = {
			role_overlap = .Subtract_Higher_Priority,
		},
	}
}

role_overlap_test_sources :: proc() -> []Role_Overlap_Source {
	result := make([]Role_Overlap_Source, 5)
	result[0] =
		role_overlap_test_source(105, .Sparse_Infill, 700, 1_000)
	result[1] =
		role_overlap_test_source(104, .Top_Skin, 500, 800)
	result[2] = role_overlap_test_source(103, .Gap, 300, 600)
	result[3] = role_overlap_test_source(102, .Bridge, 100, 400)
	result[4] = role_overlap_test_source(101, .Perimeter, 0, 200)
	return result
}

role_overlap_test_source :: proc(
	stable_id: contracts.Stable_ID,
	role: profiles.Printable_Role,
	minimum_x, maximum_x: contracts.Micrometres,
) -> Role_Overlap_Source {
	result := Role_Overlap_Source{
		stable_id = stable_id,
		layer_id = 10,
		layer_index = 0,
		role = role,
	}
	result.geometry.paths = make([]polygon.Polygon_Path, 1)
	result.geometry.points = make([]polygon.Polygon_Point, 4)
	result.geometry.paths[0] = {offset = 0, count = 4}
	copy(
		result.geometry.points,
		[]polygon.Polygon_Point{
			{minimum_x, 0},
			{maximum_x, 0},
			{maximum_x, 1_000},
			{minimum_x, 1_000},
		},
	)
	return result
}

role_overlap_test_sources_destroy :: proc(
	sources: []Role_Overlap_Source,
) {
	for &source in sources {
		polygon.polygon_set_destroy(&source.geometry)
	}
	delete(sources)
}
