package evidence

import contracts "../contracts"
import features "../features"

Path_Plan_Capture :: struct {
	bytes:      []u8,
	artifact:   Evidence_Artifact,
	additional: Capture_Usage,
}

Path_Plan_Capture_Error :: enum u8 {
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

path_plan_capture_encode :: proc(
	path: string,
	request: contracts.Evidence_Request,
	current: Capture_Usage,
	perimeter_hash, infill_hash: contracts.Content_Hash,
	result: features.Path_Plan_Result,
	limits := DEFAULT_PATH_PLAN_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Path_Plan_Capture, Path_Plan_Capture_Error) {
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

	layer_count := u64(len(result.layers))
	path_count := u64(len(result.paths))
	move_count := u64(len(result.moves))
	byte_count, size_ok := path_plan_artifact_byte_count(
		layer_count,
		path_count,
		move_count,
	)
	if !size_ok ||
	   layer_count > limits.max_layers ||
	   path_count > limits.max_paths ||
	   move_count > limits.max_moves ||
	   byte_count > limits.max_bytes {
		return {}, .Artifact_Limit
	}
	if layer_count > max(u64)-path_count ||
	   layer_count+path_count > max(u64)-move_count {
		return {}, .Artifact_Limit
	}
	additional := Capture_Usage{
		item_count = layer_count+path_count+move_count,
		byte_count = byte_count,
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

	bytes, artifact_error := path_plan_artifact_encode(
		perimeter_hash,
		infill_hash,
		result,
		limits,
		allocator,
	)
	switch artifact_error {
	case .None:
	case .Invalid_Record:
		return {}, .Invalid_Record
	case .Limit:
		return {}, .Artifact_Limit
	case .Allocation_Failed:
		return {}, .Allocation_Failed
	case .Unsupported_Version, .Malformed, .Hash_Mismatch:
		return {}, .Invalid_Record
	}

	artifact, describe_error := evidence_artifact_describe(
		path,
		PATH_PLAN_ARTIFACT_FORMAT,
		PATH_PLAN_ARTIFACT_SCHEMA_VERSION,
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

path_plan_capture_destroy :: proc(
	capture: ^Path_Plan_Capture,
	allocator := context.allocator,
) {
	delete(capture.bytes, allocator)
	evidence_artifact_destroy(&capture.artifact, allocator)
	capture^ = {}
}
