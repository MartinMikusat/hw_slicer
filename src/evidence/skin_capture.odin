package evidence

import contracts "../contracts"
import features "../features"
import slicing "../slicing"

Skin_Capture :: struct {
	bytes:      []u8,
	artifact:   Evidence_Artifact,
	additional: Capture_Usage,
}

Skin_Capture_Error :: enum u8 {
	None,
	Invalid_Request,
	Capture_Disabled,
	Level_Insufficient,
	Item_Limit,
	Byte_Limit,
	Invalid_Path,
	Invalid_Record,
	Artifact_Limit,
	Allocation_Failed,
}

skin_capture_describe :: proc(
	path: string,
	request: contracts.Evidence_Request,
	current: Capture_Usage,
	artifact_bytes: []u8,
	expected_surface_hash: contracts.Content_Hash,
	expected_layer_schedule_hash: contracts.Content_Hash,
	regions: slicing.Region_Result,
	surfaces: features.Surface_Result,
	limits := features.DEFAULT_SKIN_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Skin_Capture, Skin_Capture_Error) {
	switch request.level {
	case .Disabled:
		return {}, .Capture_Disabled
	case .Summary:
		return {}, .Level_Insufficient
	case .Primitives, .Renders:
	case:
		return {}, .Invalid_Request
	}
	if !artifact_path_valid(path) {return {}, .Invalid_Path}
	summary, preflight_error :=
		features.skin_artifact_preflight(artifact_bytes, limits)
	switch preflight_error {
	case .None:
	case .Limit:
		return {}, .Artifact_Limit
	case .Allocation_Failed:
		return {}, .Allocation_Failed
	case .Invalid_Record,
	     .Unsupported_Version,
	     .Malformed,
	     .Dependency_Mismatch,
	     .Hash_Mismatch:
		return {}, .Invalid_Record
	}
	item_count, count_ok := skin_capture_item_count(summary)
	if !count_ok {return {}, .Artifact_Limit}
	additional := Capture_Usage{
		item_count = item_count,
		byte_count = summary.byte_count,
	}
	switch capture_preflight(request, current, additional) {
	case .None:
	case .Invalid_Request:
		return {}, .Invalid_Request
	case .Capture_Disabled:
		return {}, .Capture_Disabled
	case .Item_Limit:
		return {}, .Item_Limit
	case .Byte_Limit:
		return {}, .Byte_Limit
	case .Encode_Failed,
	     .Decode_Failed,
	     .Unsupported_Version,
	     .Invalid_Record:
		return {}, .Invalid_Request
	}
	decoded, decode_error := features.skin_artifact_decode(
		artifact_bytes,
		expected_surface_hash,
		expected_layer_schedule_hash,
		regions,
		surfaces,
		limits,
		allocator,
	)
	features.skin_artifact_destroy(&decoded, allocator)
	switch decode_error {
	case .None:
	case .Allocation_Failed:
		return {}, .Allocation_Failed
	case .Limit:
		return {}, .Artifact_Limit
	case .Invalid_Record,
	     .Unsupported_Version,
	     .Malformed,
	     .Dependency_Mismatch,
	     .Hash_Mismatch:
		return {}, .Invalid_Record
	}
	bytes := make([]u8, len(artifact_bytes), allocator)
	if len(artifact_bytes) > 0 && bytes == nil {
		return {}, .Allocation_Failed
	}
	copy(bytes, artifact_bytes)
	artifact, describe_error := evidence_artifact_describe(
		path,
		features.SKIN_ARTIFACT_FORMAT,
		features.SKIN_ARTIFACT_SCHEMA_VERSION,
		additional.item_count,
		bytes,
		allocator,
	)
	if describe_error != .None {
		delete(bytes, allocator)
		if describe_error == .Invalid_Descriptor {
			return {}, .Invalid_Record
		}
		return {}, .Allocation_Failed
	}
	return {
		bytes = bytes,
		artifact = artifact,
		additional = additional,
	}, .None
}

skin_capture_item_count :: proc(
	summary: features.Skin_Artifact_Summary,
) -> (u64, bool) {
	result := summary.layer_count
	counts := [4]u64{
		summary.mask_count,
		summary.path_count,
		summary.point_count,
		summary.source_reference_count,
	}
	for count in counts {
		if result > max(u64)-count {return 0, false}
		result += count
	}
	return result, true
}

skin_capture_destroy :: proc(
	capture: ^Skin_Capture,
	allocator := context.allocator,
) {
	delete(capture.bytes, allocator)
	evidence_artifact_destroy(&capture.artifact, allocator)
	capture^ = {}
}
