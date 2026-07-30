package evidence

import contracts "../contracts"

Layer_Schedule_Capture :: struct {
	bytes:      []u8,
	artifact:   Evidence_Artifact,
	additional: Capture_Usage,
}

Layer_Schedule_Capture_Error :: enum u8 {
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

layer_schedule_capture_describe :: proc(
	path: string,
	request: contracts.Evidence_Request,
	current: Capture_Usage,
	artifact_bytes: []u8,
	limits := DEFAULT_LAYER_SCHEDULE_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Layer_Schedule_Capture, Layer_Schedule_Capture_Error) {
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
		layer_schedule_artifact_preflight(artifact_bytes, limits)
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
	additional := Capture_Usage{
		item_count = summary.layer_count,
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
	decoded, decode_error := layer_schedule_artifact_decode(
		artifact_bytes,
		limits,
		allocator,
	)
	layer_schedule_artifact_destroy(&decoded, allocator)
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
		LAYER_SCHEDULE_ARTIFACT_FORMAT,
		LAYER_SCHEDULE_ARTIFACT_SCHEMA_VERSION,
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

layer_schedule_capture_destroy :: proc(
	capture: ^Layer_Schedule_Capture,
	allocator := context.allocator,
) {
	delete(capture.bytes, allocator)
	evidence_artifact_destroy(&capture.artifact, allocator)
	capture^ = {}
}
