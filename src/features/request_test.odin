package features

import "core:testing"

import contracts "../contracts"
import polygon "../polygon"

@(test)
feature_pipeline_request_hash_binds_every_implemented_setting_test :: proc(
	t: ^testing.T,
) {
	request := feature_request_test_fixture()
	hash, hash_ok := feature_pipeline_request_hash(request)
	testing.expect(t, hash_ok)
	expected := contracts.Content_Hash{
		0xd0, 0x7c, 0xb3, 0x31, 0x5c, 0x99, 0xa2, 0x01,
		0x33, 0x84, 0xd2, 0x02, 0x21, 0x6d, 0xac, 0x44,
		0x77, 0xda, 0x94, 0x2b, 0xf3, 0xa6, 0x8d, 0x2f,
		0x6e, 0xdc, 0x49, 0x6f, 0xb1, 0xff, 0x54, 0x7d,
	}
	testing.expect_value(t, hash, expected)

	mutated := request
	mutated.spine_request_hash[0] += 1
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.surface.fill_rule = .Non_Zero
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.surface.topology_policy = .Diagnostic_Closed_Regions
	mutated.perimeter.topology_policy = .Diagnostic_Closed_Regions
	mutated.infill.topology_policy = .Diagnostic_Closed_Regions
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.perimeter.count += 1
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.perimeter.line_width += 2
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.perimeter.join_type = .Square
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.perimeter.miter_limit = 3
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.perimeter.arc_tolerance = 1
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.infill.spacing += 1
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.infill.boundary_inset += 1
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.infill.phase += 1
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.infill.base_axis = .Horizontal
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.infill.alternate_each_layer =
		!mutated.infill.alternate_each_layer
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.infill.join_type = .Square
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.infill.miter_limit = 3
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.infill.arc_tolerance = 1
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.path_plan.start.x += 1
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.path_plan.start.y += 1
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.path_plan.inner_perimeters_first =
		!mutated.path_plan.inner_perimeters_first
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.polygon_provider_name = "Clipper2-test"
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.polygon_provider_version.patch += 1
	feature_request_expect_hash_changes(t, hash, mutated)

	mutated = request
	mutated.path_plan_provider, _ = contracts.provider_descriptor_make(
		CPU_PATH_PLAN_PROVIDER_NAME,
		{0, 1, 1},
		.Plan_Paths,
	)
	feature_request_expect_hash_changes(t, hash, mutated)
}

@(test)
feature_pipeline_request_hash_rejects_incomplete_or_mixed_contracts_test :: proc(
	t: ^testing.T,
) {
	request := feature_request_test_fixture()
	request.schema_version = 0
	_, schema_ok := feature_pipeline_request_hash(request)
	testing.expect(t, !schema_ok)

	request = feature_request_test_fixture()
	request.spine_request_hash = {}
	_, parent_ok := feature_pipeline_request_hash(request)
	testing.expect(t, !parent_ok)

	request = feature_request_test_fixture()
	request.infill.topology_policy = .Diagnostic_Closed_Regions
	_, policy_ok := feature_pipeline_request_hash(request)
	testing.expect(t, !policy_ok)

	request = feature_request_test_fixture()
	request.path_plan_provider.stage = .Generate_Features
	_, provider_ok := feature_pipeline_request_hash(request)
	testing.expect(t, !provider_ok)

	request = feature_request_test_fixture()
	request.polygon_provider_name = "Clipper2\ninvalid"
	_, polygon_name_ok := feature_pipeline_request_hash(request)
	testing.expect(t, !polygon_name_ok)

	request = feature_request_test_fixture()
	request.polygon_provider_version = {}
	_, polygon_version_ok := feature_pipeline_request_hash(request)
	testing.expect(t, !polygon_version_ok)
}

feature_request_expect_hash_changes :: proc(
	t: ^testing.T,
	original: contracts.Content_Hash,
	mutated: Feature_Pipeline_Request,
) {
	mutated_hash, mutated_ok := feature_pipeline_request_hash(mutated)
	testing.expect(t, mutated_ok)
	testing.expect(t, mutated_hash != original)
}

feature_request_test_fixture :: proc() -> Feature_Pipeline_Request {
	spine_request_hash: contracts.Content_Hash
	for &byte, byte_index in spine_request_hash {
		byte = u8(byte_index+1)
	}
	return {
		schema_version = FEATURE_PIPELINE_REQUEST_SCHEMA_VERSION,
		spine_request_hash = spine_request_hash,
		surface = {
			fill_rule = .Even_Odd,
			topology_policy = .Strict_Printable,
		},
		perimeter = {
			count = 2,
			line_width = 450,
			topology_policy = .Strict_Printable,
			join_type = .Miter,
			miter_limit = 2,
			arc_tolerance = 0,
		},
		infill = {
			spacing = 5_000,
			boundary_inset = 900,
			phase = 0,
			base_axis = .Vertical,
			alternate_each_layer = true,
			topology_policy = .Strict_Printable,
			join_type = .Miter,
			miter_limit = 2,
			arc_tolerance = 0,
		},
		path_plan = {
			start = {0, 0},
			inner_perimeters_first = true,
		},
		polygon_provider_name = polygon.CLIPPER2_PROVIDER.name,
		polygon_provider_version = polygon.CLIPPER2_PROVIDER.version,
		path_plan_provider = cpu_path_plan_provider_descriptor(),
	}
}
