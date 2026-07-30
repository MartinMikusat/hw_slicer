package evidence

import "core:testing"

import contracts "../contracts"
import slicing "../slicing"

@(test)
layer_span_capture_preflights_and_describes_artifact_test :: proc(
	t: ^testing.T,
) {
	result := layer_span_artifact_test_result()
	defer slicing.layer_span_index_destroy(&result)
	bytes, encode_error := layer_span_artifact_encode(
		LAYER_SPAN_ARTIFACT_TEST_SCHEDULE_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Layer_Span_Artifact_Error.None,
	)
	capture, capture_error := layer_span_capture_describe(
		"stages/05-build-acceleration/primitives/layer-spans.bin",
		{
			level = .Primitives,
			item_limit = 16,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer layer_span_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Layer_Span_Capture_Error.None,
	)
	testing.expect_value(t, capture.additional.item_count, u64(16))
	testing.expect_value(
		t,
		capture.additional.byte_count,
		u64(len(bytes)),
	)
	testing.expect_value(
		t,
		capture.artifact.format,
		LAYER_SPAN_ARTIFACT_FORMAT,
	)
}

@(test)
layer_span_capture_rejects_budget_path_and_content_test :: proc(
	t: ^testing.T,
) {
	result := layer_span_artifact_test_result()
	defer slicing.layer_span_index_destroy(&result)
	bytes, encode_error := layer_span_artifact_encode(
		LAYER_SPAN_ARTIFACT_TEST_SCHEDULE_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Layer_Span_Artifact_Error.None,
	)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 16,
		byte_limit = u64(len(bytes)),
	}
	_, item_error := layer_span_capture_describe(
		"layer-spans.bin",
		{
			level = .Primitives,
			item_limit = 15,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	testing.expect_value(
		t,
		item_error,
		Layer_Span_Capture_Error.Item_Limit,
	)
	_, path_error := layer_span_capture_describe(
		"../layer-spans.bin",
		request,
		{},
		bytes,
	)
	testing.expect_value(
		t,
		path_error,
		Layer_Span_Capture_Error.Invalid_Path,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[64] = corrupt[64] ~ 1
	_, content_error := layer_span_capture_describe(
		"layer-spans.bin",
		request,
		{},
		corrupt,
	)
	testing.expect_value(
		t,
		content_error,
		Layer_Span_Capture_Error.Invalid_Record,
	)
}
