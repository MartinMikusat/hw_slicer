package evidence

import contracts "../contracts"
import slicing "../slicing"

REGION_ARTIFACT_SCHEMA_VERSION :: u32(1)
REGION_ARTIFACT_HEADER_SIZE    :: u32(160)
REGION_ARTIFACT_LAYER_SIZE     :: u32(24)
REGION_ARTIFACT_CONTOUR_SIZE   :: u32(64)
REGION_ARTIFACT_REGION_SIZE    :: u32(80)
REGION_ARTIFACT_INDEX_SIZE     :: u32(4)
REGION_ARTIFACT_FORMAT         :: "hws-regions-le"

REGION_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'R', 'E', 'G', 'N', '\n',
}

Region_Artifact_Limits :: struct {
	max_layers:  u64,
	max_contours: u64,
	max_regions: u64,
	max_indices: u64,
	max_bytes:   u64,
}

DEFAULT_REGION_ARTIFACT_LIMITS :: Region_Artifact_Limits{
	max_layers = 10_000_000,
	max_contours = 100_000_000,
	max_regions = 100_000_000,
	max_indices = 100_000_000,
	max_bytes = 1024*1024*1024,
}

Region_Artifact :: struct {
	topology_hash: contracts.Content_Hash,
	result_hash:   contracts.Content_Hash,
	result:        slicing.Region_Result,
}

Region_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Dependency_Mismatch,
	Hash_Mismatch,
}

region_artifact_encode :: proc(
	topology_hash: contracts.Content_Hash,
	topology: slicing.Topology_Result,
	result: slicing.Region_Result,
	limits := DEFAULT_REGION_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Region_Artifact_Error) {
	result_hash, result_ok := slicing.region_result_hash(
		topology_hash,
		topology,
		result,
	)
	if !result_ok {return nil, .Invalid_Record}
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
	   ) ||
	   byte_count > u64(max(int)) {
		return nil, .Limit
	}
	bytes := make([]u8, int(byte_count), allocator)
	if bytes == nil {return nil, .Allocation_Failed}
	for byte, byte_index in REGION_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	topology_artifact_put_u32(bytes, 8, REGION_ARTIFACT_SCHEMA_VERSION)
	topology_artifact_put_u32(bytes, 12, REGION_ARTIFACT_HEADER_SIZE)
	topology_artifact_put_u32(bytes, 16, REGION_ARTIFACT_LAYER_SIZE)
	topology_artifact_put_u32(bytes, 20, REGION_ARTIFACT_CONTOUR_SIZE)
	topology_artifact_put_u32(bytes, 24, REGION_ARTIFACT_REGION_SIZE)
	topology_artifact_put_u32(bytes, 28, REGION_ARTIFACT_INDEX_SIZE)
	for byte, byte_index in topology_hash {
		bytes[32+byte_index] = byte
	}
	for byte, byte_index in result_hash {
		bytes[64+byte_index] = byte
	}
	topology_artifact_put_u64(bytes, 96, layer_count)
	topology_artifact_put_u64(bytes, 104, contour_count)
	topology_artifact_put_u64(bytes, 112, region_count)
	topology_artifact_put_u64(bytes, 120, index_count)
	topology_artifact_put_u64(bytes, 128, result.hole_count)

	offset := int(REGION_ARTIFACT_HEADER_SIZE)
	for layer in result.layers {
		topology_artifact_put_u64(bytes, offset, layer.contour_offset)
		topology_artifact_put_u32(bytes, offset+8, layer.contour_count)
		topology_artifact_put_u64(bytes, offset+12, layer.region_offset)
		topology_artifact_put_u32(bytes, offset+20, layer.region_count)
		offset += int(REGION_ARTIFACT_LAYER_SIZE)
	}
	for contour in result.contours {
		topology_artifact_put_u64(bytes, offset, u64(contour.stable_id))
		topology_artifact_put_u32(bytes, offset+8, contour.path_index)
		topology_artifact_put_u32(bytes, offset+12, contour.parent_contour)
		topology_artifact_put_u32(bytes, offset+16, contour.region_index)
		topology_artifact_put_u32(bytes, offset+20, contour.depth)
		bytes[offset+24] = u8(contour.role)
		if contour.reverse_path {bytes[offset+25] = 1}
		region_artifact_put_bounds(bytes, offset+32, contour.bounds)
		offset += int(REGION_ARTIFACT_CONTOUR_SIZE)
	}
	for region in result.regions {
		topology_artifact_put_u64(bytes, offset, u64(region.stable_id))
		topology_artifact_put_u32(bytes, offset+8, region.layer_index)
		topology_artifact_put_u32(
			bytes,
			offset+12,
			region.outer_contour_index,
		)
		topology_artifact_put_u64(bytes, offset+16, region.contour_offset)
		topology_artifact_put_u32(bytes, offset+24, region.contour_count)
		region_artifact_put_u128(bytes, offset+32, region.filled_area_2)
		region_artifact_put_bounds(bytes, offset+48, region.bounds)
		offset += int(REGION_ARTIFACT_REGION_SIZE)
	}
	for contour_index in result.region_contour_indices {
		topology_artifact_put_u32(bytes, offset, contour_index)
		offset += int(REGION_ARTIFACT_INDEX_SIZE)
	}
	return bytes, .None
}

region_artifact_decode :: proc(
	bytes: []u8,
	topology_hash: contracts.Content_Hash,
	topology: slicing.Topology_Result,
	limits := DEFAULT_REGION_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Region_Artifact, Region_Artifact_Error) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(REGION_ARTIFACT_HEADER_SIZE) ||
	   !region_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if topology_artifact_get_u32(bytes, 8) !=
	   REGION_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	if topology_artifact_get_u32(bytes, 12) != REGION_ARTIFACT_HEADER_SIZE ||
	   topology_artifact_get_u32(bytes, 16) != REGION_ARTIFACT_LAYER_SIZE ||
	   topology_artifact_get_u32(bytes, 20) != REGION_ARTIFACT_CONTOUR_SIZE ||
	   topology_artifact_get_u32(bytes, 24) != REGION_ARTIFACT_REGION_SIZE ||
	   topology_artifact_get_u32(bytes, 28) != REGION_ARTIFACT_INDEX_SIZE ||
	   !topology_artifact_bytes_zero(bytes, 136, 160) {
		return {}, .Malformed
	}
	stored_topology_hash: contracts.Content_Hash
	copy(stored_topology_hash[:], bytes[32:64])
	if stored_topology_hash != topology_hash {
		return {}, .Dependency_Mismatch
	}
	layer_count := topology_artifact_get_u64(bytes, 96)
	contour_count := topology_artifact_get_u64(bytes, 104)
	region_count := topology_artifact_get_u64(bytes, 112)
	index_count := topology_artifact_get_u64(bytes, 120)
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
	   ) ||
	   layer_count > u64(max(int)) ||
	   contour_count > u64(max(int)) ||
	   region_count > u64(max(int)) ||
	   index_count > u64(max(int)) {
		return {}, .Limit
	}
	if byte_count != u64(len(bytes)) {return {}, .Malformed}

	artifact: Region_Artifact
	artifact.topology_hash = stored_topology_hash
	copy(artifact.result_hash[:], bytes[64:96])
	artifact.result.hole_count = topology_artifact_get_u64(bytes, 128)
	artifact.result.layers =
		make([]slicing.Region_Layer, int(layer_count), allocator)
	artifact.result.contours =
		make([]slicing.Region_Contour, int(contour_count), allocator)
	artifact.result.regions =
		make([]slicing.Region, int(region_count), allocator)
	artifact.result.region_contour_indices =
		make([]u32, int(index_count), allocator)
	if layer_count > 0 && artifact.result.layers == nil ||
	   contour_count > 0 && artifact.result.contours == nil ||
	   region_count > 0 && artifact.result.regions == nil ||
	   index_count > 0 &&
	   	artifact.result.region_contour_indices == nil {
		region_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}

	offset := int(REGION_ARTIFACT_HEADER_SIZE)
	for &layer in artifact.result.layers {
		layer.contour_offset = topology_artifact_get_u64(bytes, offset)
		layer.contour_count = topology_artifact_get_u32(bytes, offset+8)
		layer.region_offset = topology_artifact_get_u64(bytes, offset+12)
		layer.region_count = topology_artifact_get_u32(bytes, offset+20)
		offset += int(REGION_ARTIFACT_LAYER_SIZE)
	}
	for &contour in artifact.result.contours {
		if !topology_artifact_bytes_zero(bytes, offset+26, offset+32) ||
		   bytes[offset+24] < u8(slicing.Region_Contour_Role.Outer) ||
		   bytes[offset+24] > u8(slicing.Region_Contour_Role.Hole) ||
		   bytes[offset+25] > 1 {
			region_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		contour.stable_id = contracts.Stable_ID(
			topology_artifact_get_u64(bytes, offset),
		)
		contour.path_index = topology_artifact_get_u32(bytes, offset+8)
		contour.parent_contour =
			topology_artifact_get_u32(bytes, offset+12)
		contour.region_index =
			topology_artifact_get_u32(bytes, offset+16)
		contour.depth = topology_artifact_get_u32(bytes, offset+20)
		contour.role =
			transmute(slicing.Region_Contour_Role)bytes[offset+24]
		contour.reverse_path = bytes[offset+25] == 1
		contour.bounds = region_artifact_get_bounds(bytes, offset+32)
		offset += int(REGION_ARTIFACT_CONTOUR_SIZE)
	}
	for &region in artifact.result.regions {
		if !topology_artifact_bytes_zero(bytes, offset+28, offset+32) {
			region_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		region.stable_id = contracts.Stable_ID(
			topology_artifact_get_u64(bytes, offset),
		)
		region.layer_index = topology_artifact_get_u32(bytes, offset+8)
		region.outer_contour_index =
			topology_artifact_get_u32(bytes, offset+12)
		region.contour_offset =
			topology_artifact_get_u64(bytes, offset+16)
		region.contour_count =
			topology_artifact_get_u32(bytes, offset+24)
		region.filled_area_2 = region_artifact_get_u128(bytes, offset+32)
		region.bounds = region_artifact_get_bounds(bytes, offset+48)
		offset += int(REGION_ARTIFACT_REGION_SIZE)
	}
	for &contour_index in artifact.result.region_contour_indices {
		contour_index = topology_artifact_get_u32(bytes, offset)
		offset += int(REGION_ARTIFACT_INDEX_SIZE)
	}
	calculated_hash, result_ok := slicing.region_result_hash(
		topology_hash,
		topology,
		artifact.result,
	)
	if !result_ok {
		region_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		region_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

region_artifact_destroy :: proc(
	artifact: ^Region_Artifact,
	allocator := context.allocator,
) {
	slicing.region_result_destroy(&artifact.result, allocator)
	artifact^ = {}
}

region_artifact_counts_fit_limits :: proc(
	layer_count, contour_count, region_count, index_count, byte_count: u64,
	limits: Region_Artifact_Limits,
) -> bool {
	return layer_count <= limits.max_layers &&
		contour_count <= limits.max_contours &&
		region_count <= limits.max_regions &&
		index_count <= limits.max_indices &&
		byte_count <= limits.max_bytes
}

region_artifact_byte_count :: proc(
	layer_count, contour_count, region_count, index_count: u64,
) -> (u64, bool) {
	result := u64(REGION_ARTIFACT_HEADER_SIZE)
	counts := [4]u64{
		layer_count,
		contour_count,
		region_count,
		index_count,
	}
	sizes := [4]u64{
		u64(REGION_ARTIFACT_LAYER_SIZE),
		u64(REGION_ARTIFACT_CONTOUR_SIZE),
		u64(REGION_ARTIFACT_REGION_SIZE),
		u64(REGION_ARTIFACT_INDEX_SIZE),
	}
	for count, count_index in counts {
		if count > (max(u64)-result)/sizes[count_index] {
			return 0, false
		}
		result += count*sizes[count_index]
	}
	return result, true
}

region_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for expected, byte_index in REGION_ARTIFACT_MAGIC {
		if bytes[byte_index] != expected {return false}
	}
	return true
}

region_artifact_put_bounds :: proc(
	bytes: []u8,
	offset: int,
	bounds: slicing.Region_Bounds,
) {
	topology_artifact_put_i64(bytes, offset, i64(bounds.minimum.x))
	topology_artifact_put_i64(bytes, offset+8, i64(bounds.minimum.y))
	topology_artifact_put_i64(bytes, offset+16, i64(bounds.maximum.x))
	topology_artifact_put_i64(bytes, offset+24, i64(bounds.maximum.y))
}

region_artifact_get_bounds :: proc(
	bytes: []u8,
	offset: int,
) -> slicing.Region_Bounds {
	return {
		minimum = {
			contracts.Micrometres(
				topology_artifact_get_i64(bytes, offset),
			),
			contracts.Micrometres(
				topology_artifact_get_i64(bytes, offset+8),
			),
		},
		maximum = {
			contracts.Micrometres(
				topology_artifact_get_i64(bytes, offset+16),
			),
			contracts.Micrometres(
				topology_artifact_get_i64(bytes, offset+24),
			),
		},
	}
}

region_artifact_put_u128 :: proc(
	bytes: []u8,
	offset: int,
	value: u128,
) {
	for byte_index in 0..<16 {
		bytes[offset+byte_index] =
			u8(value>>u128(byte_index*8))
	}
}

region_artifact_get_u128 :: proc(bytes: []u8, offset: int) -> u128 {
	value: u128
	for byte_index in 0..<16 {
		value |= u128(bytes[offset+byte_index])<<u128(byte_index*8)
	}
	return value
}
