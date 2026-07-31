package evidence

import "core:testing"

import contracts "../contracts"
import features "../features"
import geometry "../geometry"
import polygon "../polygon"
import slicing "../slicing"

Skin_Capture_Test_Fixture :: struct {
	regions:        slicing.Region_Result,
	surfaces:       features.Surface_Result,
	result:         features.Skin_Result,
	layer_heights:  []contracts.Micrometres,
	surface_hash:   contracts.Content_Hash,
	schedule_hash:  contracts.Content_Hash,
	bytes:          []u8,
}

@(test)
skin_capture_preflights_and_describes_artifact_test :: proc(t: ^testing.T) {
	fixture := skin_capture_test_fixture(t)
	defer skin_capture_test_fixture_destroy(&fixture)
	capture, capture_error := skin_capture_describe(
		"stages/09-generate-features/primitives/skins.bin",
		{
			level = .Primitives,
			item_limit = 7,
			byte_limit = u64(len(fixture.bytes)),
		},
		{},
		fixture.bytes,
		fixture.surface_hash,
		fixture.schedule_hash,
		fixture.regions,
		fixture.surfaces,
	)
	defer skin_capture_destroy(&capture)
	testing.expect_value(t, capture_error, Skin_Capture_Error.None)
	testing.expect_value(t, capture.additional.item_count, u64(7))
	testing.expect_value(
		t,
		capture.additional.byte_count,
		u64(len(fixture.bytes)),
	)
	testing.expect_value(
		t,
		capture.artifact.format,
		features.SKIN_ARTIFACT_FORMAT,
	)
	decoded, decode_error := features.skin_artifact_decode(
		capture.bytes,
		fixture.surface_hash,
		fixture.schedule_hash,
		fixture.regions,
		fixture.surfaces,
	)
	defer features.skin_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		features.Skin_Artifact_Error.None,
	)
	testing.expect_value(t, len(decoded.result.layers), 1)
	testing.expect_value(t, len(decoded.result.masks), 1)
	testing.expect_value(t, len(decoded.result.source_references), 1)
}

@(test)
skin_capture_rejects_budget_path_dependency_and_content_test :: proc(
	t: ^testing.T,
) {
	fixture := skin_capture_test_fixture(t)
	defer skin_capture_test_fixture_destroy(&fixture)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 7,
		byte_limit = u64(len(fixture.bytes)),
	}
	_, item_error := skin_capture_describe(
		"skins.bin",
		{
			level = .Primitives,
			item_limit = 6,
			byte_limit = u64(len(fixture.bytes)),
		},
		{},
		fixture.bytes,
		fixture.surface_hash,
		fixture.schedule_hash,
		fixture.regions,
		fixture.surfaces,
	)
	testing.expect_value(t, item_error, Skin_Capture_Error.Item_Limit)
	_, path_error := skin_capture_describe(
		"../skins.bin",
		request,
		{},
		fixture.bytes,
		fixture.surface_hash,
		fixture.schedule_hash,
		fixture.regions,
		fixture.surfaces,
	)
	testing.expect_value(t, path_error, Skin_Capture_Error.Invalid_Path)
	wrong_hash := fixture.surface_hash
	wrong_hash[0] = wrong_hash[0] ~ 1
	_, dependency_error := skin_capture_describe(
		"skins.bin",
		request,
		{},
		fixture.bytes,
		wrong_hash,
		fixture.schedule_hash,
		fixture.regions,
		fixture.surfaces,
	)
	testing.expect_value(
		t,
		dependency_error,
		Skin_Capture_Error.Invalid_Record,
	)
	corrupt := make([]u8, len(fixture.bytes), context.temp_allocator)
	copy(corrupt, fixture.bytes)
	corrupt[112] = corrupt[112] ~ 1
	_, content_error := skin_capture_describe(
		"skins.bin",
		request,
		{},
		corrupt,
		fixture.surface_hash,
		fixture.schedule_hash,
		fixture.regions,
		fixture.surfaces,
	)
	testing.expect_value(
		t,
		content_error,
		Skin_Capture_Error.Invalid_Record,
	)
}

skin_capture_test_fixture :: proc(t: ^testing.T) -> Skin_Capture_Test_Fixture {
	fixture: Skin_Capture_Test_Fixture
	fixture.surface_hash[0] = 0x51
	fixture.schedule_hash[0] = 0x61
	fixture.layer_heights = make([]contracts.Micrometres, 1)
	fixture.layer_heights[0] = 200
	fixture.regions.layers = make([]slicing.Region_Layer, 1)
	fixture.regions.regions = make([]slicing.Region, 1)
	region_id := contracts.Stable_ID(0x1122334455667788)
	fixture.regions.layers[0] = {region_count = 1}
	fixture.regions.regions[0] = {
		stable_id = region_id,
		layer_index = 0,
	}
	fixture.surfaces.layers = make([]features.Surface_Layer, 1)
	fixture.surfaces.masks = make([]features.Surface_Mask, 1)
	surface_id := contracts.Stable_ID(0x8877665544332211)
	fixture.surfaces.layers[0] = {mask_count = 1}
	fixture.surfaces.masks[0] = {
		stable_id = surface_id,
		region_id = region_id,
		region_index = 0,
		layer_index = 0,
		kind = .Bottom_Exposed,
	}
	fixture.result.config = {
		fill_rule = .Even_Odd,
		top = {200, 1},
		bottom = {200, 1},
	}
	fixture.result.layers = make([]features.Skin_Layer, 1)
	fixture.result.masks = make([]features.Skin_Mask, 1)
	fixture.result.paths = make([]features.Skin_Path, 1)
	fixture.result.points = make([]polygon.Polygon_Point, 3)
	fixture.result.source_references =
		make([]features.Skin_Source_Reference, 1)
	fixture.result.bottom_mask_count = 1
	fixture.result.layers[0] = {
		mask_count = 1,
		path_count = 1,
		source_reference_count = 1,
	}
	ordinal, ordinal_ok := features.feature_skin_ordinal(.Bottom)
	testing.expect(t, ordinal_ok)
	mask_id := contracts.stable_id_child(
		region_id,
		.Feature,
		ordinal,
	)
	fixture.result.masks[0] = {
		stable_id = mask_id,
		region_id = region_id,
		region_index = 0,
		layer_index = 0,
		kind = .Bottom,
		path_count = 1,
		point_count = 3,
		source_reference_count = 1,
	}
	fixture.result.paths[0] = {
		stable_id = contracts.stable_id_child(mask_id, .Path, 0),
		mask_id = mask_id,
		mask_path_index = 0,
		point_count = 3,
		signed_area_2 = 10_000,
		winding = geometry.Predicate_Sign.Positive,
	}
	fixture.result.points[0] = {0, 0}
	fixture.result.points[1] = {100, 0}
	fixture.result.points[2] = {0, 100}
	fixture.result.source_references[0] = {
		surface_mask_index = 0,
		surface_id = surface_id,
		surface_kind = .Bottom_Exposed,
		source_layer_index = 0,
	}
	encode_error: features.Skin_Artifact_Error
	fixture.bytes, encode_error = features.skin_artifact_encode(
		fixture.surface_hash,
		fixture.schedule_hash,
		fixture.layer_heights,
		fixture.regions,
		fixture.surfaces,
		fixture.result,
	)
	testing.expect_value(
		t,
		encode_error,
		features.Skin_Artifact_Error.None,
	)
	testing.expect_value(t, len(fixture.bytes), 528)
	return fixture
}

skin_capture_test_fixture_destroy :: proc(fixture: ^Skin_Capture_Test_Fixture) {
	delete(fixture.layer_heights)
	slicing.region_result_destroy(&fixture.regions)
	features.surface_result_destroy(&fixture.surfaces)
	features.skin_result_destroy(&fixture.result)
	delete(fixture.bytes)
	fixture^ = {}
}
