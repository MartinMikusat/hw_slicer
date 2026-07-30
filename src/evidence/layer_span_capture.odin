package evidence

import contracts "../contracts"

Layer_Span_Capture :: struct {
	bytes:      []u8,
	artifact:   Evidence_Artifact,
	additional: Capture_Usage,
}

Layer_Span_Capture_Error :: enum u8 {
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

layer_span_capture_describe :: proc(
	path: string,
	request: contracts.Evidence_Request,
	current: Capture_Usage,
	artifact_bytes: []u8,
	limits := DEFAULT_LAYER_SPAN_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Layer_Span_Capture, Layer_Span_Capture_Error) {
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
		layer_span_artifact_preflight(artifact_bytes, limits)
	switch preflight_error {
	case .None:
	case .Limit:
		return {}, .Artifact_Limit
	case .Allocation_Failed:
		return {}, .Allocation_Failed
	case .Invalid_Record,
	     .Unsupported_Version,
	     .Malformed,
	     .Hash_Mismatch:
		return {}, .Invalid_Record
	}
	item_count, count_ok := layer_span_capture_item_count(summary)
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
	decoded, decode_error := layer_span_artifact_decode(
		artifact_bytes,
		limits,
		allocator,
	)
	layer_span_artifact_destroy(&decoded, allocator)
	switch decode_error {
	case .None:
	case .Allocation_Failed:
		return {}, .Allocation_Failed
	case .Limit:
		return {}, .Artifact_Limit
	case .Invalid_Record,
	     .Unsupported_Version,
	     .Malformed,
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
		LAYER_SPAN_ARTIFACT_FORMAT,
		LAYER_SPAN_ARTIFACT_SCHEMA_VERSION,
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

layer_span_capture_item_count :: proc(
	summary: Layer_Span_Artifact_Summary,
) -> (u64, bool) {
	result := summary.triangle_count
	if result > max(u64)-summary.layer_count {return 0, false}
	result += summary.layer_count
	if result > max(u64)-summary.pair_count {return 0, false}
	return result+summary.pair_count, true
}

layer_span_capture_destroy :: proc(
	capture: ^Layer_Span_Capture,
	allocator := context.allocator,
) {
	delete(capture.bytes, allocator)
	evidence_artifact_destroy(&capture.artifact, allocator)
	capture^ = {}
}
