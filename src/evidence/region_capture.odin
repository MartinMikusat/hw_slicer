package evidence

import contracts "../contracts"
import slicing "../slicing"

Region_Capture :: struct {
	bytes:      []u8,
	artifact:   Evidence_Artifact,
	additional: Capture_Usage,
}

Region_Capture_Error :: enum u8 {
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

region_capture_encode :: proc(
	path: string,
	request: contracts.Evidence_Request,
	current: Capture_Usage,
	topology_hash: contracts.Content_Hash,
	topology: slicing.Topology_Result,
	result: slicing.Region_Result,
	limits := DEFAULT_REGION_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Region_Capture, Region_Capture_Error) {
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
	contour_count := u64(len(result.contours))
	region_count := u64(len(result.regions))
	index_count := u64(len(result.region_contour_indices))
	byte_count, size_ok := region_artifact_byte_count(
		layer_count,
		contour_count,
		region_count,
		index_count,
	)
	if !size_ok ||
	   !region_artifact_counts_fit_limits(
	   	layer_count,
	   	contour_count,
	   	region_count,
	   	index_count,
	   	byte_count,
	   	limits,
	   ) {
		return {}, .Artifact_Limit
	}
	counts := [4]u64{
		layer_count,
		contour_count,
		region_count,
		index_count,
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
	bytes, artifact_error := region_artifact_encode(
		topology_hash,
		topology,
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
	case .Unsupported_Version,
	     .Malformed,
	     .Dependency_Mismatch,
	     .Hash_Mismatch:
		return {}, .Invalid_Record
	}
	artifact, describe_error := evidence_artifact_describe(
		path,
		REGION_ARTIFACT_FORMAT,
		REGION_ARTIFACT_SCHEMA_VERSION,
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

region_capture_destroy :: proc(
	capture: ^Region_Capture,
	allocator := context.allocator,
) {
	delete(capture.bytes, allocator)
	evidence_artifact_destroy(&capture.artifact, allocator)
	capture^ = {}
}
