package evidence

import "core:testing"

import contracts "../contracts"
import features "../features"
import polygon "../polygon"

@(test)
surface_capture_preflights_and_describes_artifact_test :: proc(
	t: ^testing.T,
) {
	bytes := surface_capture_test_artifact(t)
	defer delete(bytes)
	capture, capture_error := surface_capture_describe(
		"stages/09-generate-features/primitives/surfaces.bin",
		{
			level = .Primitives,
			item_limit = 1,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer surface_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Surface_Capture_Error.None,
	)
	testing.expect_value(t, capture.additional.item_count, u64(1))
	testing.expect_value(
		t,
		capture.additional.byte_count,
		u64(len(bytes)),
	)
	testing.expect_value(
		t,
		capture.artifact.format,
		features.SURFACE_ARTIFACT_FORMAT,
	)
	decoded, decode_error :=
		features.surface_artifact_decode(capture.bytes)
	defer features.surface_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		features.Surface_Artifact_Error.None,
	)
	testing.expect_value(t, len(decoded.result.layers), 1)
	testing.expect_value(t, len(decoded.result.masks), 0)
	testing.expect_value(t, len(decoded.result.paths), 0)
	testing.expect_value(t, len(decoded.result.points), 0)
}

@(test)
surface_capture_rejects_budget_path_and_content_test :: proc(
	t: ^testing.T,
) {
	bytes := surface_capture_test_artifact(t)
	defer delete(bytes)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 1,
		byte_limit = u64(len(bytes)),
	}
	_, item_error := surface_capture_describe(
		"surfaces.bin",
		{
			level = .Primitives,
			item_limit = 0,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	testing.expect_value(
		t,
		item_error,
		Surface_Capture_Error.Item_Limit,
	)
	_, path_error := surface_capture_describe(
		"../surfaces.bin",
		request,
		{},
		bytes,
	)
	testing.expect_value(
		t,
		path_error,
		Surface_Capture_Error.Invalid_Path,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[72] = corrupt[72] ~ 1
	_, content_error := surface_capture_describe(
		"surfaces.bin",
		request,
		{},
		corrupt,
	)
	testing.expect_value(
		t,
		content_error,
		Surface_Capture_Error.Invalid_Record,
	)
}

surface_capture_test_artifact :: proc(t: ^testing.T) -> []u8 {
	result := features.Surface_Result{
		config = {
			fill_rule = polygon.Polygon_Fill_Rule.Even_Odd,
			topology_policy = .Strict_Printable,
		},
		layers = []features.Surface_Layer{{}},
	}
	result_hash, result_ok := features.surface_result_hash(
		SURFACE_CAPTURE_TEST_REGION_HASH,
		result,
	)
	testing.expect(t, result_ok)
	byte_count, byte_count_ok :=
		features.surface_artifact_byte_count(1, 0, 0, 0)
	testing.expect(t, byte_count_ok)
	bytes := make([]u8, int(byte_count))
	testing.expect(t, bytes != nil)
	for byte, byte_index in features.SURFACE_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	features.surface_artifact_put_u32(
		bytes,
		8,
		features.SURFACE_ARTIFACT_SCHEMA_VERSION,
	)
	features.surface_artifact_put_u32(
		bytes,
		12,
		features.SURFACE_ARTIFACT_HEADER_SIZE,
	)
	features.surface_artifact_put_u32(
		bytes,
		16,
		features.SURFACE_ARTIFACT_LAYER_SIZE,
	)
	features.surface_artifact_put_u32(
		bytes,
		20,
		features.SURFACE_ARTIFACT_MASK_SIZE,
	)
	features.surface_artifact_put_u32(
		bytes,
		24,
		features.SURFACE_ARTIFACT_PATH_SIZE,
	)
	features.surface_artifact_put_u32(
		bytes,
		28,
		features.SURFACE_ARTIFACT_POINT_SIZE,
	)
	features.surface_artifact_put_u32(
		bytes,
		32,
		features.SCHEMA_VERSION_SURFACE_HASH,
	)
	features.surface_artifact_put_hash(
		bytes,
		40,
		SURFACE_CAPTURE_TEST_REGION_HASH,
	)
	features.surface_artifact_put_hash(bytes, 72, result_hash)
	bytes[108] = u8(result.config.fill_rule)
	features.surface_artifact_put_u64(bytes, 128, 1)
	return bytes
}

SURFACE_CAPTURE_TEST_REGION_HASH :: contracts.Content_Hash{
	0x03, 0x25, 0x47, 0x69, 0x8b, 0xad, 0xcf, 0xe1,
	0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
	0xf0, 0xde, 0xbc, 0x9a, 0x78, 0x56, 0x34, 0x12,
	0xe1, 0xcf, 0xad, 0x8b, 0x69, 0x47, 0x25, 0x03,
}
