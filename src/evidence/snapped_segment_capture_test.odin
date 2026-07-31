package evidence

import "core:testing"

import contracts "../contracts"
import slicing "../slicing"

@(test)
snapped_segment_capture_preflights_and_describes_artifact_test :: proc(
	t: ^testing.T,
) {
	result := snapped_segment_artifact_test_result()
	defer slicing.snapped_segments_destroy(&result)
	bytes, encode_error := snapped_segment_artifact_encode(
		SNAPPED_SEGMENT_ARTIFACT_TEST_PARENT_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Snapped_Segment_Artifact_Error.None,
	)
	capture, capture_error := snapped_segment_capture_describe(
		"stages/06-intersect/primitives/snapped-segments.bin",
		{
			level = .Primitives,
			item_limit = 4,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer snapped_segment_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Snapped_Segment_Capture_Error.None,
	)
	testing.expect_value(t, capture.additional.item_count, u64(4))
	testing.expect_value(
		t,
		capture.additional.byte_count,
		u64(len(bytes)),
	)
	testing.expect_value(
		t,
		capture.artifact.format,
		SNAPPED_SEGMENT_ARTIFACT_FORMAT,
	)
}

@(test)
snapped_segment_capture_rejects_budget_path_and_content_test :: proc(
	t: ^testing.T,
) {
	result := snapped_segment_artifact_test_result()
	defer slicing.snapped_segments_destroy(&result)
	bytes, encode_error := snapped_segment_artifact_encode(
		SNAPPED_SEGMENT_ARTIFACT_TEST_PARENT_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Snapped_Segment_Artifact_Error.None,
	)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 4,
		byte_limit = u64(len(bytes)),
	}
	_, item_error := snapped_segment_capture_describe(
		"snapped-segments.bin",
		{
			level = .Primitives,
			item_limit = 3,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	testing.expect_value(
		t,
		item_error,
		Snapped_Segment_Capture_Error.Item_Limit,
	)
	_, path_error := snapped_segment_capture_describe(
		"../snapped-segments.bin",
		request,
		{},
		bytes,
	)
	testing.expect_value(
		t,
		path_error,
		Snapped_Segment_Capture_Error.Invalid_Path,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[64] = corrupt[64] ~ 1
	_, content_error := snapped_segment_capture_describe(
		"snapped-segments.bin",
		request,
		{},
		corrupt,
	)
	testing.expect_value(
		t,
		content_error,
		Snapped_Segment_Capture_Error.Invalid_Record,
	)
}
