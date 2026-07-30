package evidence

import "core:testing"

import contracts "../contracts"
import features "../features"

@(test)
unified_source_capture_preflights_and_describes_artifact_test :: proc(
	t: ^testing.T,
) {
	bytes := unified_path_source_capture_test_artifact(t)
	defer delete(bytes)
	capture, capture_error := unified_path_source_capture_describe(
		"stages/09-generate-features/primitives/unified-sources.bin",
		{
			level = .Primitives,
			item_limit = 1,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer unified_path_source_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Unified_Path_Source_Capture_Error.None,
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
		features.UNIFIED_PATH_SOURCE_ARTIFACT_FORMAT,
	)
	decoded, decode_error :=
		features.unified_path_source_artifact_decode(capture.bytes)
	defer features.unified_path_source_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		features.Unified_Path_Source_Artifact_Error.None,
	)
	testing.expect_value(t, len(decoded.result.layers), 1)
	testing.expect_value(t, len(decoded.result.sources), 0)
	testing.expect_value(t, len(decoded.result.points), 0)
}

@(test)
unified_source_capture_rejects_budget_path_and_content_test :: proc(
	t: ^testing.T,
) {
	bytes := unified_path_source_capture_test_artifact(t)
	defer delete(bytes)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 1,
		byte_limit = u64(len(bytes)),
	}
	_, item_error := unified_path_source_capture_describe(
		"unified-sources.bin",
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
		Unified_Path_Source_Capture_Error.Item_Limit,
	)
	_, path_error := unified_path_source_capture_describe(
		"../unified-sources.bin",
		request,
		{},
		bytes,
	)
	testing.expect_value(
		t,
		path_error,
		Unified_Path_Source_Capture_Error.Invalid_Path,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[32] = corrupt[32] ~ 1
	_, content_error := unified_path_source_capture_describe(
		"unified-sources.bin",
		request,
		{},
		corrupt,
	)
	testing.expect_value(
		t,
		content_error,
		Unified_Path_Source_Capture_Error.Invalid_Record,
	)
}

unified_path_source_capture_test_artifact :: proc(
	t: ^testing.T,
) -> []u8 {
	dependencies := features.Unified_Path_Source_Hash_Dependencies{
		perimeter_hash = UNIFIED_SOURCE_CAPTURE_TEST_HASH,
		bridge_hash = UNIFIED_SOURCE_CAPTURE_TEST_HASH,
		gap_hash = UNIFIED_SOURCE_CAPTURE_TEST_HASH,
		solid_hash = UNIFIED_SOURCE_CAPTURE_TEST_HASH,
		infill_hash = UNIFIED_SOURCE_CAPTURE_TEST_HASH,
		support_hash = UNIFIED_SOURCE_CAPTURE_TEST_HASH,
		process_hash = UNIFIED_SOURCE_CAPTURE_TEST_HASH,
	}
	result := features.Unified_Path_Source_Result{
		inner_perimeters_first = true,
		nominal_line_width = 450,
		layers = []features.Unified_Path_Source_Layer{{}},
	}
	result_hash, result_ok :=
		features.unified_path_source_result_content_hash(
			dependencies,
			result,
		)
	testing.expect(t, result_ok)
	byte_count, byte_count_ok :=
		features.unified_path_source_artifact_byte_count(1, 0, 0)
	testing.expect(t, byte_count_ok)
	bytes := make([]u8, int(byte_count))
	testing.expect(t, bytes != nil)
	for byte, byte_index in features.UNIFIED_PATH_SOURCE_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	features.unified_path_source_artifact_put_u32(
		bytes,
		8,
		features.UNIFIED_PATH_SOURCE_ARTIFACT_SCHEMA_VERSION,
	)
	features.unified_path_source_artifact_put_u32(
		bytes,
		12,
		features.UNIFIED_PATH_SOURCE_ARTIFACT_HEADER_SIZE,
	)
	features.unified_path_source_artifact_put_u32(
		bytes,
		16,
		features.UNIFIED_PATH_SOURCE_ARTIFACT_LAYER_SIZE,
	)
	features.unified_path_source_artifact_put_u32(
		bytes,
		20,
		features.UNIFIED_PATH_SOURCE_ARTIFACT_SOURCE_SIZE,
	)
	features.unified_path_source_artifact_put_u32(
		bytes,
		24,
		features.UNIFIED_PATH_SOURCE_ARTIFACT_POINT_SIZE,
	)
	features.unified_path_source_artifact_put_u32(
		bytes,
		28,
		features.SCHEMA_VERSION_UNIFIED_PATH_SOURCE_HASH,
	)
	features.unified_path_source_artifact_put_hash(
		bytes,
		32,
		dependencies.perimeter_hash,
	)
	features.unified_path_source_artifact_put_hash(
		bytes,
		64,
		dependencies.bridge_hash,
	)
	features.unified_path_source_artifact_put_hash(
		bytes,
		96,
		dependencies.gap_hash,
	)
	features.unified_path_source_artifact_put_hash(
		bytes,
		128,
		dependencies.solid_hash,
	)
	features.unified_path_source_artifact_put_hash(
		bytes,
		160,
		dependencies.infill_hash,
	)
	features.unified_path_source_artifact_put_hash(
		bytes,
		192,
		dependencies.support_hash,
	)
	features.unified_path_source_artifact_put_hash(
		bytes,
		224,
		dependencies.process_hash,
	)
	features.unified_path_source_artifact_put_hash(
		bytes,
		256,
		result_hash,
	)
	bytes[288] = 1
	features.unified_path_source_artifact_put_i64(
		bytes,
		296,
		i64(result.nominal_line_width),
	)
	features.unified_path_source_artifact_put_u64(bytes, 304, 1)
	return bytes
}

UNIFIED_SOURCE_CAPTURE_TEST_HASH :: contracts.Content_Hash{
	0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
	0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
	0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
	0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01,
}
