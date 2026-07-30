package features

import "core:testing"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"

@(test)
support_paths_emit_separate_regular_and_interface_spacing_test :: proc(
	t: ^testing.T,
) {
	support_geometry := support_path_test_geometry()
	defer support_geometry_result_destroy(&support_geometry)
	process := support_path_test_process(100, 500_000, 100)
	result, error := support_paths_generate(
		support_geometry,
		process,
		polygon.CLIPPER2_PROVIDER,
	)
	defer support_path_result_destroy(&result)
	testing.expect_value(t, error, Support_Path_Error.None)
	testing.expect_value(t, result.pattern, profiles.Support_Pattern.Rectilinear)
	testing.expect_value(t, result.line_width, contracts.Micrometres(100))
	testing.expect_value(
		t,
		result.regular_spacing,
		contracts.Micrometres(200),
	)
	testing.expect_value(
		t,
		result.interface_spacing,
		contracts.Micrometres(100),
	)
	testing.expect_value(
		t,
		result.boundary_inset,
		contracts.Micrometres(50),
	)
	testing.expect_value(t, result.regular_path_count, u64(4))
	testing.expect_value(t, result.interface_path_count, u64(9))
	testing.expect_value(t, len(result.paths), 13)
	testing.expect_value(t, len(result.hits), 26)
	testing.expect_value(t, result.scanline_count, u64(13))
	testing.expect_value(t, result.layers[0].path_count, u32(4))
	testing.expect_value(t, result.layers[1].path_count, u32(9))
	regular := result.paths[0]
	testing.expect_value(t, regular.kind, Support_Geometry_Kind.Regular)
	testing.expect_value(t, regular.role, profiles.Printable_Role.Support)
	testing.expect_value(t, regular.axis, Infill_Axis.Vertical)
	testing.expect_value(
		t,
		regular.point_a,
		polygon.Polygon_Point{200, 50},
	)
	testing.expect_value(
		t,
		regular.point_b,
		polygon.Polygon_Point{200, 950},
	)
	interface := result.paths[result.layers[1].path_offset]
	testing.expect_value(
		t,
		interface.kind,
		Support_Geometry_Kind.Interface,
	)
	testing.expect_value(
		t,
		interface.role,
		profiles.Printable_Role.Support_Interface,
	)
	testing.expect_value(t, interface.axis, Infill_Axis.Horizontal)
	testing.expect_value(
		t,
		interface.point_a,
		polygon.Polygon_Point{50, 100},
	)
	testing.expect_value(
		t,
		interface.point_b,
		polygon.Polygon_Point{950, 100},
	)
	for path, path_index in result.paths {
		testing.expect_value(t, path.line_width, result.line_width)
		testing.expect_value(
			t,
			path.path_set_id,
			contracts.stable_id_child(
				path.geometry_mask_id,
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
		testing.expect_value(
			t,
			path.hit_offset,
			u64(path_index)*2,
		)
	}
}

@(test)
support_path_density_spacing_rounds_up_test :: proc(t: ^testing.T) {
	spacing, spacing_ok := support_path_regular_spacing(101, 300_000)
	inset, inset_ok := support_path_boundary_inset(101)
	testing.expect(t, spacing_ok && inset_ok)
	testing.expect_value(t, spacing, contracts.Micrometres(337))
	testing.expect_value(t, inset, contracts.Micrometres(51))
	_, zero_density_ok := support_path_regular_spacing(101, 0)
	testing.expect(t, !zero_density_ok)
}

@(test)
support_paths_enforce_path_limit_test :: proc(t: ^testing.T) {
	support_geometry := support_path_test_geometry()
	defer support_geometry_result_destroy(&support_geometry)
	result, error := support_paths_generate(
		support_geometry,
		support_path_test_process(100, 500_000, 100),
		polygon.CLIPPER2_PROVIDER,
		Support_Path_Limits{
			max_scanlines = 100,
			max_paths = 3,
			polygon = polygon.DEFAULT_POLYGON_LIMITS,
		},
	)
	defer support_path_result_destroy(&result)
	testing.expect_value(t, error, Support_Path_Error.Path_Limit)
}

@(test)
support_path_hash_rejects_mutated_role_test :: proc(t: ^testing.T) {
	support_geometry := support_path_test_geometry()
	defer support_geometry_result_destroy(&support_geometry)
	process := support_path_test_process(100, 500_000, 100)
	result, error := support_paths_generate(
		support_geometry,
		process,
		polygon.CLIPPER2_PROVIDER,
	)
	defer support_path_result_destroy(&result)
	testing.expect_value(t, error, Support_Path_Error.None)
	hash, hash_ok := support_path_result_hash(
		{},
		{},
		support_geometry,
		process,
		polygon.CLIPPER2_PROVIDER,
		result,
	)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0x9f, 0x7e, 0x0f, 0x2d, 0xa4, 0x46, 0xb4, 0xa2,
		0xbb, 0x60, 0x07, 0xe4, 0x0a, 0x2f, 0x5c, 0x0e,
		0x63, 0x1e, 0xdb, 0xaf, 0x7b, 0xd2, 0x7d, 0xdf,
		0xad, 0xef, 0x5d, 0x8a, 0x35, 0x21, 0x93, 0xd3,
	}
	testing.expect_value(t, hash, expected_hash)
	result.paths[0].role = .Bridge
	_, mutated_hash_ok := support_path_result_hash(
		{},
		{},
		support_geometry,
		process,
		polygon.CLIPPER2_PROVIDER,
		result,
	)
	testing.expect(t, !mutated_hash_ok)
}

support_path_test_process :: proc(
	line_width: contracts.Micrometres,
	density: profiles.Ratio_Ppm,
	interface_spacing: contracts.Micrometres,
) -> profiles.Resolved_Process_Profile {
	result := support_face_test_process(45_000)
	result.source.nominal_line_width = line_width
	result.source.support_mode = .Everywhere
	result.source.support_clearance_xy = 300
	result.source.support_clearance_z = 200
	result.source.support_expansion = 200
	result.source.support_density = density
	result.source.support_interface_layers = 2
	result.source.support_interface_spacing = interface_spacing
	return result
}

support_path_test_geometry :: proc() -> Support_Geometry_Result {
	result := Support_Geometry_Result{
		config = support_demand_test_config(),
		mode = .Everywhere,
		clearance_xy = 300,
		clearance_z = 200,
		expansion = 200,
		interface_layers = 2,
		layers = make([]Support_Geometry_Layer, 2),
		masks = make([]Support_Geometry_Mask, 2),
		paths = make([]Support_Geometry_Path, 2),
		points = make([]polygon.Polygon_Point, 8),
		regular_mask_count = 1,
		interface_mask_count = 1,
	}
	for layer_index in 0..<2 {
		kind := Support_Geometry_Kind.Regular
		role := profiles.Printable_Role.Support
		if layer_index == 1 {
			kind = .Interface
			role = .Support_Interface
		}
		layer_id := contracts.Stable_ID(10+layer_index)
		ordinal, _ := feature_support_geometry_ordinal(kind)
		mask_id := contracts.stable_id_child(
			layer_id,
			.Feature,
			ordinal,
		)
		result.layers[layer_index] = {
			mask_offset = u64(layer_index),
			mask_count = 1,
			path_offset = u64(layer_index),
			path_count = 1,
		}
		result.masks[layer_index] = {
			stable_id = mask_id,
			layer_id = layer_id,
			layer_index = u32(layer_index),
			kind = kind,
			role = role,
			path_offset = u64(layer_index),
			path_count = 1,
			point_offset = u64(layer_index*4),
			point_count = 4,
		}
		result.paths[layer_index] = {
			stable_id = contracts.stable_id_child(
				mask_id,
				.Path,
				0,
			),
			mask_id = mask_id,
			mask_path_index = 0,
			point_offset = u64(layer_index*4),
			point_count = 4,
			signed_area_2 = 2_000_000,
			winding = geometry.Predicate_Sign.Positive,
		}
		copy(
			result.points[layer_index*4:layer_index*4+4],
			[]polygon.Polygon_Point{
				{0, 0},
				{1_000, 0},
				{1_000, 1_000},
				{0, 1_000},
			},
		)
	}
	return result
}
