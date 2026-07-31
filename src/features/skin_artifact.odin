package features

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import slicing "../slicing"

SKIN_ARTIFACT_SCHEMA_VERSION         :: u32(1)
SKIN_ARTIFACT_HEADER_SIZE            :: u32(256)
SKIN_ARTIFACT_LAYER_HEIGHT_SIZE      :: u32(8)
SKIN_ARTIFACT_LAYER_SIZE             :: u32(48)
SKIN_ARTIFACT_MASK_SIZE              :: u32(80)
SKIN_ARTIFACT_PATH_SIZE              :: u32(64)
SKIN_ARTIFACT_POINT_SIZE             :: u32(16)
SKIN_ARTIFACT_SOURCE_REFERENCE_SIZE  :: u32(24)
SKIN_ARTIFACT_FORMAT                 :: "hws-skins-le"

SKIN_ARTIFACT_MAGIC :: [8]u8{
	'H', 'W', 'S', 'S', 'K', 'I', 'N', '\n',
}

Skin_Artifact_Limits :: struct {
	max_layers:            u64,
	max_masks:             u64,
	max_paths:             u64,
	max_points:            u64,
	max_source_references: u64,
	max_bytes:             u64,
}

DEFAULT_SKIN_ARTIFACT_LIMITS :: Skin_Artifact_Limits{
	max_layers = 10_000_000,
	max_masks = 200_000_000,
	max_paths = 400_000_000,
	max_points = 2_000_000_000,
	max_source_references = 1_000_000_000,
	max_bytes = 2*1024*1024*1024,
}

Skin_Artifact :: struct {
	surface_hash:        contracts.Content_Hash,
	layer_schedule_hash: contracts.Content_Hash,
	result_hash:         contracts.Content_Hash,
	layer_heights:       []contracts.Micrometres,
	result:              Skin_Result,
}

Skin_Artifact_Summary :: struct {
	layer_count:            u64,
	mask_count:             u64,
	path_count:             u64,
	point_count:            u64,
	source_reference_count: u64,
	bottom_mask_count:      u64,
	top_mask_count:         u64,
	top_bottom_mask_count:  u64,
	byte_count:             u64,
}

Skin_Artifact_Error :: enum u8 {
	None,
	Invalid_Record,
	Unsupported_Version,
	Malformed,
	Limit,
	Allocation_Failed,
	Dependency_Mismatch,
	Hash_Mismatch,
}

skin_artifact_encode :: proc(
	surface_hash: contracts.Content_Hash,
	layer_schedule_hash: contracts.Content_Hash,
	layer_heights: []contracts.Micrometres,
	regions: slicing.Region_Result,
	surfaces: Surface_Result,
	result: Skin_Result,
	limits := DEFAULT_SKIN_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> ([]u8, Skin_Artifact_Error) {
	result_hash, result_ok := skin_result_hash(
		surface_hash,
		layer_schedule_hash,
		layer_heights,
		regions,
		surfaces,
		result,
	)
	if !result_ok {return nil, .Invalid_Record}
	layer_count := u64(len(result.layers))
	mask_count := u64(len(result.masks))
	path_count := u64(len(result.paths))
	point_count := u64(len(result.points))
	source_reference_count := u64(len(result.source_references))
	byte_count, size_ok := skin_artifact_byte_count(
		layer_count,
		mask_count,
		path_count,
		point_count,
		source_reference_count,
	)
	if !size_ok ||
	   !skin_artifact_counts_fit_limits(
			layer_count,
			mask_count,
			path_count,
			point_count,
			source_reference_count,
			byte_count,
			limits,
	   ) ||
	   byte_count > u64(max(int)) {
		return nil, .Limit
	}
	bytes := make([]u8, int(byte_count), allocator)
	if bytes == nil {return nil, .Allocation_Failed}
	for byte, byte_index in SKIN_ARTIFACT_MAGIC {
		bytes[byte_index] = byte
	}
	surface_artifact_put_u32(bytes, 8, SKIN_ARTIFACT_SCHEMA_VERSION)
	surface_artifact_put_u32(bytes, 12, SKIN_ARTIFACT_HEADER_SIZE)
	surface_artifact_put_u32(bytes, 16, SKIN_ARTIFACT_LAYER_HEIGHT_SIZE)
	surface_artifact_put_u32(bytes, 20, SKIN_ARTIFACT_LAYER_SIZE)
	surface_artifact_put_u32(bytes, 24, SKIN_ARTIFACT_MASK_SIZE)
	surface_artifact_put_u32(bytes, 28, SKIN_ARTIFACT_PATH_SIZE)
	surface_artifact_put_u32(bytes, 32, SKIN_ARTIFACT_POINT_SIZE)
	surface_artifact_put_u32(
		bytes,
		36,
		SKIN_ARTIFACT_SOURCE_REFERENCE_SIZE,
	)
	surface_artifact_put_u32(bytes, 40, SCHEMA_VERSION_SKIN_HASH)
	surface_artifact_put_hash(bytes, 48, surface_hash)
	surface_artifact_put_hash(bytes, 80, layer_schedule_hash)
	surface_artifact_put_hash(bytes, 112, result_hash)
	bytes[144] = u8(result.config.fill_rule)
	surface_artifact_put_i64(bytes, 152, i64(result.config.top.thickness))
	surface_artifact_put_u32(bytes, 160, result.config.top.minimum_layers)
	surface_artifact_put_i64(bytes, 168, i64(result.config.bottom.thickness))
	surface_artifact_put_u32(bytes, 176, result.config.bottom.minimum_layers)
	surface_artifact_put_u64(bytes, 184, result.bottom_mask_count)
	surface_artifact_put_u64(bytes, 192, result.top_mask_count)
	surface_artifact_put_u64(bytes, 200, result.top_bottom_mask_count)
	surface_artifact_put_u64(bytes, 208, layer_count)
	surface_artifact_put_u64(bytes, 216, layer_count)
	surface_artifact_put_u64(bytes, 224, mask_count)
	surface_artifact_put_u64(bytes, 232, path_count)
	surface_artifact_put_u64(bytes, 240, point_count)
	surface_artifact_put_u64(bytes, 248, source_reference_count)

	offset := int(SKIN_ARTIFACT_HEADER_SIZE)
	for height in layer_heights {
		surface_artifact_put_i64(bytes, offset, i64(height))
		offset += int(SKIN_ARTIFACT_LAYER_HEIGHT_SIZE)
	}
	for layer in result.layers {
		surface_artifact_put_u64(bytes, offset, layer.mask_offset)
		surface_artifact_put_u32(bytes, offset+8, layer.mask_count)
		surface_artifact_put_u64(bytes, offset+16, layer.path_offset)
		surface_artifact_put_u32(bytes, offset+24, layer.path_count)
		surface_artifact_put_u64(
			bytes,
			offset+32,
			layer.source_reference_offset,
		)
		surface_artifact_put_u32(
			bytes,
			offset+40,
			layer.source_reference_count,
		)
		offset += int(SKIN_ARTIFACT_LAYER_SIZE)
	}
	for mask in result.masks {
		surface_artifact_put_u64(bytes, offset, u64(mask.stable_id))
		surface_artifact_put_u64(bytes, offset+8, u64(mask.region_id))
		surface_artifact_put_u32(bytes, offset+16, mask.region_index)
		surface_artifact_put_u32(bytes, offset+20, mask.layer_index)
		bytes[offset+24] = u8(mask.kind)
		surface_artifact_put_u64(bytes, offset+32, mask.path_offset)
		surface_artifact_put_u32(bytes, offset+40, mask.path_count)
		surface_artifact_put_u64(bytes, offset+48, mask.point_offset)
		surface_artifact_put_u32(bytes, offset+56, mask.point_count)
		surface_artifact_put_u64(
			bytes,
			offset+64,
			mask.source_reference_offset,
		)
		surface_artifact_put_u32(
			bytes,
			offset+72,
			mask.source_reference_count,
		)
		offset += int(SKIN_ARTIFACT_MASK_SIZE)
	}
	for path in result.paths {
		surface_artifact_put_u64(bytes, offset, u64(path.stable_id))
		surface_artifact_put_u64(bytes, offset+8, u64(path.mask_id))
		surface_artifact_put_u32(bytes, offset+16, path.mask_path_index)
		surface_artifact_put_u32(bytes, offset+20, path.point_count)
		surface_artifact_put_u64(bytes, offset+24, path.point_offset)
		surface_artifact_put_i128(bytes, offset+32, path.signed_area_2)
		bytes[offset+48] = u8(i8(path.winding)+1)
		offset += int(SKIN_ARTIFACT_PATH_SIZE)
	}
	for point in result.points {
		surface_artifact_put_i64(bytes, offset, i64(point.x))
		surface_artifact_put_i64(bytes, offset+8, i64(point.y))
		offset += int(SKIN_ARTIFACT_POINT_SIZE)
	}
	for reference in result.source_references {
		surface_artifact_put_u32(
			bytes,
			offset,
			reference.surface_mask_index,
		)
		bytes[offset+4] = u8(reference.surface_kind)
		surface_artifact_put_u32(
			bytes,
			offset+8,
			reference.source_layer_index,
		)
		surface_artifact_put_u64(
			bytes,
			offset+16,
			u64(reference.surface_id),
		)
		offset += int(SKIN_ARTIFACT_SOURCE_REFERENCE_SIZE)
	}
	return bytes, .None
}

skin_artifact_decode :: proc(
	bytes: []u8,
	expected_surface_hash: contracts.Content_Hash,
	expected_layer_schedule_hash: contracts.Content_Hash,
	regions: slicing.Region_Result,
	surfaces: Surface_Result,
	limits := DEFAULT_SKIN_ARTIFACT_LIMITS,
	allocator := context.allocator,
) -> (Skin_Artifact, Skin_Artifact_Error) {
	summary, preflight_error := skin_artifact_preflight(bytes, limits)
	if preflight_error != .None {return {}, preflight_error}
	artifact: Skin_Artifact
	surface_artifact_get_hash(bytes, 48, &artifact.surface_hash)
	surface_artifact_get_hash(bytes, 80, &artifact.layer_schedule_hash)
	if artifact.surface_hash != expected_surface_hash ||
	   artifact.layer_schedule_hash != expected_layer_schedule_hash {
		return {}, .Dependency_Mismatch
	}
	surface_artifact_get_hash(bytes, 112, &artifact.result_hash)
	result := &artifact.result
	result.config.fill_rule = transmute(polygon.Polygon_Fill_Rule)bytes[144]
	result.config.top.thickness = contracts.Micrometres(
		surface_artifact_get_i64(bytes, 152),
	)
	result.config.top.minimum_layers = surface_artifact_get_u32(bytes, 160)
	result.config.bottom.thickness = contracts.Micrometres(
		surface_artifact_get_i64(bytes, 168),
	)
	result.config.bottom.minimum_layers = surface_artifact_get_u32(bytes, 176)
	result.bottom_mask_count = summary.bottom_mask_count
	result.top_mask_count = summary.top_mask_count
	result.top_bottom_mask_count = summary.top_bottom_mask_count
	artifact.layer_heights = make(
		[]contracts.Micrometres,
		int(summary.layer_count),
		allocator,
	)
	result.layers = make([]Skin_Layer, int(summary.layer_count), allocator)
	result.masks = make([]Skin_Mask, int(summary.mask_count), allocator)
	result.paths = make([]Skin_Path, int(summary.path_count), allocator)
	result.points = make([]polygon.Polygon_Point, int(summary.point_count), allocator)
	result.source_references = make(
		[]Skin_Source_Reference,
		int(summary.source_reference_count),
		allocator,
	)
	if summary.layer_count > 0 &&
	   (artifact.layer_heights == nil || result.layers == nil) ||
	   summary.mask_count > 0 && result.masks == nil ||
	   summary.path_count > 0 && result.paths == nil ||
	   summary.point_count > 0 && result.points == nil ||
	   summary.source_reference_count > 0 &&
	    result.source_references == nil {
		skin_artifact_destroy(&artifact, allocator)
		return {}, .Allocation_Failed
	}

	offset := int(SKIN_ARTIFACT_HEADER_SIZE)
	for &height in artifact.layer_heights {
		height = contracts.Micrometres(surface_artifact_get_i64(bytes, offset))
		offset += int(SKIN_ARTIFACT_LAYER_HEIGHT_SIZE)
	}
	for &layer in result.layers {
		if !surface_artifact_bytes_zero(bytes, offset+12, offset+16) ||
		   !surface_artifact_bytes_zero(bytes, offset+28, offset+32) ||
		   !surface_artifact_bytes_zero(bytes, offset+44, offset+48) {
			skin_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		layer.mask_offset = surface_artifact_get_u64(bytes, offset)
		layer.mask_count = surface_artifact_get_u32(bytes, offset+8)
		layer.path_offset = surface_artifact_get_u64(bytes, offset+16)
		layer.path_count = surface_artifact_get_u32(bytes, offset+24)
		layer.source_reference_offset =
			surface_artifact_get_u64(bytes, offset+32)
		layer.source_reference_count =
			surface_artifact_get_u32(bytes, offset+40)
		offset += int(SKIN_ARTIFACT_LAYER_SIZE)
	}
	for &mask in result.masks {
		if !surface_artifact_bytes_zero(bytes, offset+25, offset+32) ||
		   !surface_artifact_bytes_zero(bytes, offset+44, offset+48) ||
		   !surface_artifact_bytes_zero(bytes, offset+60, offset+64) ||
		   !surface_artifact_bytes_zero(bytes, offset+76, offset+80) {
			skin_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		mask.stable_id = contracts.Stable_ID(
			surface_artifact_get_u64(bytes, offset),
		)
		mask.region_id = contracts.Stable_ID(
			surface_artifact_get_u64(bytes, offset+8),
		)
		mask.region_index = surface_artifact_get_u32(bytes, offset+16)
		mask.layer_index = surface_artifact_get_u32(bytes, offset+20)
		mask.kind = transmute(Skin_Kind)bytes[offset+24]
		mask.path_offset = surface_artifact_get_u64(bytes, offset+32)
		mask.path_count = surface_artifact_get_u32(bytes, offset+40)
		mask.point_offset = surface_artifact_get_u64(bytes, offset+48)
		mask.point_count = surface_artifact_get_u32(bytes, offset+56)
		mask.source_reference_offset =
			surface_artifact_get_u64(bytes, offset+64)
		mask.source_reference_count =
			surface_artifact_get_u32(bytes, offset+72)
		offset += int(SKIN_ARTIFACT_MASK_SIZE)
	}
	for &path in result.paths {
		if bytes[offset+48] > 2 ||
		   !surface_artifact_bytes_zero(bytes, offset+49, offset+64) {
			skin_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		path.stable_id = contracts.Stable_ID(
			surface_artifact_get_u64(bytes, offset),
		)
		path.mask_id = contracts.Stable_ID(
			surface_artifact_get_u64(bytes, offset+8),
		)
		path.mask_path_index = surface_artifact_get_u32(bytes, offset+16)
		path.point_count = surface_artifact_get_u32(bytes, offset+20)
		path.point_offset = surface_artifact_get_u64(bytes, offset+24)
		path.signed_area_2 = surface_artifact_get_i128(bytes, offset+32)
		path.winding = geometry.Predicate_Sign(i8(bytes[offset+48])-1)
		offset += int(SKIN_ARTIFACT_PATH_SIZE)
	}
	for &point in result.points {
		point.x = contracts.Micrometres(
			surface_artifact_get_i64(bytes, offset),
		)
		point.y = contracts.Micrometres(
			surface_artifact_get_i64(bytes, offset+8),
		)
		offset += int(SKIN_ARTIFACT_POINT_SIZE)
	}
	for &reference in result.source_references {
		if !surface_artifact_bytes_zero(bytes, offset+5, offset+8) ||
		   !surface_artifact_bytes_zero(bytes, offset+12, offset+16) {
			skin_artifact_destroy(&artifact, allocator)
			return {}, .Malformed
		}
		reference.surface_mask_index =
			surface_artifact_get_u32(bytes, offset)
		reference.surface_kind = transmute(Surface_Kind)bytes[offset+4]
		reference.source_layer_index =
			surface_artifact_get_u32(bytes, offset+8)
		reference.surface_id = contracts.Stable_ID(
			surface_artifact_get_u64(bytes, offset+16),
		)
		offset += int(SKIN_ARTIFACT_SOURCE_REFERENCE_SIZE)
	}
	calculated_hash, result_ok := skin_result_hash(
		artifact.surface_hash,
		artifact.layer_schedule_hash,
		artifact.layer_heights,
		regions,
		surfaces,
		artifact.result,
	)
	if !result_ok {
		skin_artifact_destroy(&artifact, allocator)
		return {}, .Invalid_Record
	}
	if calculated_hash != artifact.result_hash {
		skin_artifact_destroy(&artifact, allocator)
		return {}, .Hash_Mismatch
	}
	return artifact, .None
}

skin_artifact_preflight :: proc(
	bytes: []u8,
	limits := DEFAULT_SKIN_ARTIFACT_LIMITS,
) -> (Skin_Artifact_Summary, Skin_Artifact_Error) {
	if u64(len(bytes)) > limits.max_bytes {return {}, .Limit}
	if len(bytes) < int(SKIN_ARTIFACT_HEADER_SIZE) ||
	   !skin_artifact_magic_valid(bytes) {
		return {}, .Malformed
	}
	if surface_artifact_get_u32(bytes, 8) != SKIN_ARTIFACT_SCHEMA_VERSION {
		return {}, .Unsupported_Version
	}
	layout_valid :=
		surface_artifact_get_u32(bytes, 12) == SKIN_ARTIFACT_HEADER_SIZE &&
		surface_artifact_get_u32(bytes, 16) ==
			SKIN_ARTIFACT_LAYER_HEIGHT_SIZE &&
		surface_artifact_get_u32(bytes, 20) == SKIN_ARTIFACT_LAYER_SIZE &&
		surface_artifact_get_u32(bytes, 24) == SKIN_ARTIFACT_MASK_SIZE &&
		surface_artifact_get_u32(bytes, 28) == SKIN_ARTIFACT_PATH_SIZE &&
		surface_artifact_get_u32(bytes, 32) == SKIN_ARTIFACT_POINT_SIZE &&
		surface_artifact_get_u32(bytes, 36) ==
			SKIN_ARTIFACT_SOURCE_REFERENCE_SIZE &&
		surface_artifact_get_u32(bytes, 40) == SCHEMA_VERSION_SKIN_HASH
	config := Skin_Config{
		fill_rule = transmute(polygon.Polygon_Fill_Rule)bytes[144],
		top = {
			contracts.Micrometres(surface_artifact_get_i64(bytes, 152)),
			surface_artifact_get_u32(bytes, 160),
		},
		bottom = {
			contracts.Micrometres(surface_artifact_get_i64(bytes, 168)),
			surface_artifact_get_u32(bytes, 176),
		},
	}
	if !layout_valid ||
	   !surface_artifact_bytes_zero(bytes, 44, 48) ||
	   !surface_artifact_bytes_zero(bytes, 145, 152) ||
	   !surface_artifact_bytes_zero(bytes, 164, 168) ||
	   !surface_artifact_bytes_zero(bytes, 180, 184) ||
	   !skin_config_valid(config) {
		return {}, .Malformed
	}
	bottom_mask_count := surface_artifact_get_u64(bytes, 184)
	top_mask_count := surface_artifact_get_u64(bytes, 192)
	top_bottom_mask_count := surface_artifact_get_u64(bytes, 200)
	layer_height_count := surface_artifact_get_u64(bytes, 208)
	layer_count := surface_artifact_get_u64(bytes, 216)
	mask_count := surface_artifact_get_u64(bytes, 224)
	path_count := surface_artifact_get_u64(bytes, 232)
	point_count := surface_artifact_get_u64(bytes, 240)
	source_reference_count := surface_artifact_get_u64(bytes, 248)
	byte_count, size_ok := skin_artifact_byte_count(
		layer_count,
		mask_count,
		path_count,
		point_count,
		source_reference_count,
	)
	if !size_ok ||
	   !skin_artifact_counts_fit_limits(
			layer_count,
			mask_count,
			path_count,
			point_count,
			source_reference_count,
			byte_count,
			limits,
	   ) ||
	   layer_count > u64(max(int)) ||
	   mask_count > u64(max(int)) ||
	   path_count > u64(max(int)) ||
	   point_count > u64(max(int)) ||
	   source_reference_count > u64(max(int)) {
		return {}, .Limit
	}
	if layer_height_count != layer_count ||
	   bottom_mask_count > mask_count ||
	   top_mask_count > mask_count-bottom_mask_count ||
	   top_bottom_mask_count >
	    mask_count-bottom_mask_count-top_mask_count ||
	   bottom_mask_count+top_mask_count+top_bottom_mask_count != mask_count ||
	   byte_count != u64(len(bytes)) {
		return {}, .Malformed
	}
	return {
		layer_count = layer_count,
		mask_count = mask_count,
		path_count = path_count,
		point_count = point_count,
		source_reference_count = source_reference_count,
		bottom_mask_count = bottom_mask_count,
		top_mask_count = top_mask_count,
		top_bottom_mask_count = top_bottom_mask_count,
		byte_count = byte_count,
	}, .None
}

skin_artifact_destroy :: proc(
	artifact: ^Skin_Artifact,
	allocator := context.allocator,
) {
	delete(artifact.layer_heights, allocator)
	skin_result_destroy(&artifact.result, allocator)
	artifact^ = {}
}

skin_artifact_counts_fit_limits :: proc(
	layer_count, mask_count, path_count, point_count,
	source_reference_count, byte_count: u64,
	limits: Skin_Artifact_Limits,
) -> bool {
	return layer_count <= limits.max_layers &&
		mask_count <= limits.max_masks &&
		path_count <= limits.max_paths &&
		point_count <= limits.max_points &&
		source_reference_count <= limits.max_source_references &&
		byte_count <= limits.max_bytes
}

skin_artifact_byte_count :: proc(
	layer_count, mask_count, path_count, point_count,
	source_reference_count: u64,
) -> (u64, bool) {
	result := u64(SKIN_ARTIFACT_HEADER_SIZE)
	counts := [6]u64{
		layer_count,
		layer_count,
		mask_count,
		path_count,
		point_count,
		source_reference_count,
	}
	sizes := [6]u64{
		u64(SKIN_ARTIFACT_LAYER_HEIGHT_SIZE),
		u64(SKIN_ARTIFACT_LAYER_SIZE),
		u64(SKIN_ARTIFACT_MASK_SIZE),
		u64(SKIN_ARTIFACT_PATH_SIZE),
		u64(SKIN_ARTIFACT_POINT_SIZE),
		u64(SKIN_ARTIFACT_SOURCE_REFERENCE_SIZE),
	}
	for count, count_index in counts {
		if count > (max(u64)-result)/sizes[count_index] {
			return 0, false
		}
		result += count*sizes[count_index]
	}
	return result, true
}

skin_artifact_magic_valid :: proc(bytes: []u8) -> bool {
	for expected, byte_index in SKIN_ARTIFACT_MAGIC {
		if bytes[byte_index] != expected {return false}
	}
	return true
}
