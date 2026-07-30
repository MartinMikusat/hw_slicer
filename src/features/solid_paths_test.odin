package features

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"

@(test)
solid_paths_emit_configured_angled_skin_lines_test :: proc(
	t: ^testing.T,
) {
	process := solid_path_test_process()
	overlap := solid_path_test_overlap(t, process, false)
	defer role_overlap_result_destroy(&overlap)
	result, error := solid_paths_generate(
		overlap,
		process,
		polygon.CLIPPER2_PROVIDER,
	)
	defer solid_path_result_destroy(&result)
	testing.expect_value(t, error, Solid_Path_Error.None)
	testing.expect_value(t, result.spacing, contracts.Micrometres(200))
	testing.expect_value(t, result.line_width, contracts.Micrometres(100))
	testing.expect_value(
		t,
		result.boundary_inset,
		contracts.Micrometres(50),
	)
	testing.expect_value(t, result.skin_mask_count, u64(2))
	testing.expect_value(t, result.collapsed_count, u64(0))
	testing.expect(t, result.layers[0].path_count > 0)
	testing.expect(t, result.layers[1].path_count > 0)
	testing.expect_value(
		t,
		result.paths[result.layers[0].path_offset].angle,
		profiles.Angle_Millidegrees(45_000),
	)
	testing.expect_value(
		t,
		result.paths[result.layers[1].path_offset].angle,
		profiles.Angle_Millidegrees(135_000),
	)
	scaled_spacing :=
		i128(i64(result.spacing))*i128(result.direction_scale)
	for path, path_index in result.paths {
		testing.expect_value(t, path.role, profiles.Printable_Role.Top_Skin)
		testing.expect_value(t, path.line_width, result.line_width)
		testing.expect_value(
			t,
			path.path_set_id,
			contracts.stable_id_child(
				path.overlap_mask_id,
				.Feature,
				0,
			),
		)
		testing.expect_value(
			t,
			path.stable_id,
			contracts.stable_id_child(
				path.path_set_id,
				.Path,
				path.mask_path_index,
			),
		)
		testing.expect_value(t, path.hit_offset, u64(path_index)*2)
		testing.expect_value(
			t,
			path.line_coordinate_scaled%scaled_spacing,
			i128(0),
		)
		for hit in result.hits[path.hit_offset:path.hit_offset+2] {
			x, x_error, x_ok := infill_rational_round(
				hit.x_numerator,
				hit.denominator,
			)
			y, y_error, y_ok := infill_rational_round(
				hit.y_numerator,
				hit.denominator,
			)
			testing.expect(t, x_ok && y_ok)
			testing.expect_value(
				t,
				hit.point,
				polygon.Polygon_Point{x, y},
			)
			testing.expect_value(t, hit.error_x_numerator, x_error)
			testing.expect_value(t, hit.error_y_numerator, y_error)
		}
	}
}

@(test)
solid_path_angle_schedule_wraps_at_half_turn_test :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		solid_path_layer_angle(45_000, 90_000, 0),
		profiles.Angle_Millidegrees(45_000),
	)
	testing.expect_value(
		t,
		solid_path_layer_angle(45_000, 90_000, 1),
		profiles.Angle_Millidegrees(135_000),
	)
	testing.expect_value(
		t,
		solid_path_layer_angle(45_000, 90_000, 2),
		profiles.Angle_Millidegrees(45_000),
	)
}

@(test)
solid_paths_preserve_collapsed_skin_mask_count_test :: proc(
	t: ^testing.T,
) {
	process := solid_path_test_process()
	overlap := solid_path_test_overlap(t, process, true)
	defer role_overlap_result_destroy(&overlap)
	result, error := solid_paths_generate(
		overlap,
		process,
		polygon.CLIPPER2_PROVIDER,
	)
	defer solid_path_result_destroy(&result)
	testing.expect_value(t, error, Solid_Path_Error.None)
	testing.expect_value(t, result.skin_mask_count, u64(1))
	testing.expect_value(t, result.collapsed_count, u64(1))
	testing.expect_value(t, len(result.paths), 0)
}

@(test)
solid_path_hash_rejects_mutated_angle_test :: proc(t: ^testing.T) {
	process := solid_path_test_process()
	overlap := solid_path_test_overlap(t, process, false)
	defer role_overlap_result_destroy(&overlap)
	result, error := solid_paths_generate(
		overlap,
		process,
		polygon.CLIPPER2_PROVIDER,
	)
	defer solid_path_result_destroy(&result)
	testing.expect_value(t, error, Solid_Path_Error.None)
	hash, hash_ok := solid_path_result_hash(
		{},
		{},
		overlap,
		process,
		polygon.CLIPPER2_PROVIDER,
		result,
	)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0xe1, 0x11, 0x4c, 0xe9, 0x72, 0xfd, 0x69, 0x0a,
		0x2e, 0x1a, 0x80, 0x99, 0x53, 0xfe, 0x52, 0x39,
		0x4c, 0x3b, 0xed, 0xf5, 0x53, 0xc5, 0xd7, 0x74,
		0xcb, 0xeb, 0x30, 0x67, 0xea, 0x34, 0x5d, 0x83,
	}
	testing.expect_value(t, hash, expected_hash)
	result.paths[0].angle = 0
	_, mutated_hash_ok := solid_path_result_hash(
		{},
		{},
		overlap,
		process,
		polygon.CLIPPER2_PROVIDER,
		result,
	)
	testing.expect(t, !mutated_hash_ok)
}

solid_path_test_process :: proc() -> profiles.Resolved_Process_Profile {
	return {
		source = {
			nominal_line_width = 100,
			solid_infill_spacing = 200,
			solid_infill_base_angle = 45_000,
			solid_infill_angle_step = 90_000,
			role_overlap = .Subtract_Higher_Priority,
		},
	}
}

solid_path_test_overlap :: proc(
	t: ^testing.T,
	process: profiles.Resolved_Process_Profile,
	collapse_skin: bool,
) -> Role_Overlap_Result {
	layer_count := 2
	source_count := 2
	if collapse_skin {
		layer_count = 1
		source_count = 2
	}
	layer_ids := make([]contracts.Stable_ID, layer_count)
	for _, layer_index in layer_ids {
		layer_ids[layer_index] = contracts.Stable_ID(10+layer_index)
	}
	sources := make([]Role_Overlap_Source, source_count)
	if collapse_skin {
		sources[0] = solid_path_test_source(
			1,
			10,
			0,
			.Perimeter,
		)
		sources[1] = solid_path_test_source(
			2,
			10,
			0,
			.Top_Skin,
		)
	} else {
		sources[0] = solid_path_test_source(
			1,
			10,
			0,
			.Top_Skin,
		)
		sources[1] = solid_path_test_source(
			2,
			11,
			1,
			.Top_Skin,
		)
	}
	result, error := role_overlap_resolve(
		layer_ids,
		sources,
		process,
		polygon.CLIPPER2_PROVIDER,
		.Even_Odd,
	)
	for &source in sources {
		polygon.polygon_set_destroy(&source.geometry)
	}
	delete(sources)
	delete(layer_ids)
	testing.expect_value(t, error, Role_Overlap_Error.None)
	return result
}

solid_path_test_source :: proc(
	stable_id, layer_id: contracts.Stable_ID,
	layer_index: u32,
	role: profiles.Printable_Role,
) -> Role_Overlap_Source {
	result := Role_Overlap_Source{
		stable_id = stable_id,
		layer_id = layer_id,
		layer_index = layer_index,
		role = role,
	}
	result.geometry.paths = make([]polygon.Polygon_Path, 1)
	result.geometry.points = make([]polygon.Polygon_Point, 4)
	result.geometry.paths[0] = {offset = 0, count = 4}
	copy(
		result.geometry.points,
		[]polygon.Polygon_Point{
			{0, 0},
			{1_000, 0},
			{1_000, 1_000},
			{0, 1_000},
		},
	)
	return result
}
