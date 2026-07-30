package evidence

import "core:testing"

import contracts "../contracts"
import slicing "../slicing"

@(test)
cpu_intersection_capture_preflights_and_describes_artifact_test :: proc(
	t: ^testing.T,
) {
	result := cpu_intersection_artifact_test_result()
	defer slicing.cpu_intersections_destroy(&result)
	bytes, encode_error := cpu_intersection_artifact_encode(
		CPU_INTERSECTION_ARTIFACT_TEST_SPAN_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		CPU_Intersection_Artifact_Error.None,
	)
	capture, capture_error := cpu_intersection_capture_describe(
		"stages/06-intersect/primitives/cpu-intersections.bin",
		{
			level = .Primitives,
			item_limit = 5,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer cpu_intersection_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		CPU_Intersection_Capture_Error.None,
	)
	testing.expect_value(t, capture.additional.item_count, u64(5))
	testing.expect_value(
		t,
		capture.additional.byte_count,
		u64(len(bytes)),
	)
	testing.expect_value(
		t,
		capture.artifact.format,
		CPU_INTERSECTION_ARTIFACT_FORMAT,
	)
}

@(test)
cpu_intersection_capture_rejects_budget_path_and_content_test :: proc(
	t: ^testing.T,
) {
	result := cpu_intersection_artifact_test_result()
	defer slicing.cpu_intersections_destroy(&result)
	bytes, encode_error := cpu_intersection_artifact_encode(
		CPU_INTERSECTION_ARTIFACT_TEST_SPAN_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		CPU_Intersection_Artifact_Error.None,
	)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 5,
		byte_limit = u64(len(bytes)),
	}
	_, item_error := cpu_intersection_capture_describe(
		"cpu-intersections.bin",
		{
			level = .Primitives,
			item_limit = 4,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	testing.expect_value(
		t,
		item_error,
		CPU_Intersection_Capture_Error.Item_Limit,
	)
	_, path_error := cpu_intersection_capture_describe(
		"../cpu-intersections.bin",
		request,
		{},
		bytes,
	)
	testing.expect_value(
		t,
		path_error,
		CPU_Intersection_Capture_Error.Invalid_Path,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[64] = corrupt[64] ~ 1
	_, content_error := cpu_intersection_capture_describe(
		"cpu-intersections.bin",
		request,
		{},
		corrupt,
	)
	testing.expect_value(
		t,
		content_error,
		CPU_Intersection_Capture_Error.Invalid_Record,
	)
}
