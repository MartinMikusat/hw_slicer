package evidence

import contracts "../contracts"
import slicing "../slicing"

Topology_Capture :: struct {
	bytes:      []u8,
	artifact:   Evidence_Artifact,
	additional: Capture_Usage,
}

Topology_Capture_Error :: enum u8 {
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

topology_capture_encode :: proc(
	path: string,
	request: contracts.Evidence_Request,
	current: Capture_Usage,
	snapped_hash: contracts.Content_Hash,
	source_segment_count: int,
	result: slicing.Topology_Result,
	limits := DEFAULT_TOPOLOGY_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Topology_Capture, Topology_Capture_Error) {
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
	if source_segment_count < 0 {return {}, .Invalid_Record}

	layer_count := u64(len(result.layers))
	vertex_count := u64(len(result.vertices))
	path_count := u64(len(result.paths))
	path_vertex_count := u64(len(result.path_vertex_indices))
	path_segment_count := u64(len(result.path_segment_indices))
	byte_count, size_ok := topology_artifact_byte_count(
		layer_count,
		vertex_count,
		path_count,
		path_vertex_count,
		path_segment_count,
	)
	if !size_ok ||
	   !topology_artifact_counts_fit_limits(
	   	u64(source_segment_count),
	   	layer_count,
	   	vertex_count,
	   	path_count,
	   	path_vertex_count,
	   	path_segment_count,
	   	byte_count,
	   	limits,
	   ) {
		return {}, .Artifact_Limit
	}
	counts := [5]u64{
		layer_count,
		vertex_count,
		path_count,
		path_vertex_count,
		path_segment_count,
	}
	item_count: u64
	for count in counts {
		if item_count > max(u64)-count {return {}, .Artifact_Limit}
		item_count += count
	}
	additional := Capture_Usage{
		item_count = item_count,
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

	bytes, artifact_error := topology_artifact_encode(
		snapped_hash,
		source_segment_count,
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
		TOPOLOGY_ARTIFACT_FORMAT,
		TOPOLOGY_ARTIFACT_SCHEMA_VERSION,
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

topology_capture_destroy :: proc(
	capture: ^Topology_Capture,
	allocator := context.allocator,
) {
	delete(capture.bytes, allocator)
	evidence_artifact_destroy(&capture.artifact, allocator)
	capture^ = {}
}
