package features

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"

SCHEMA_VERSION_ROLE_OVERLAP_HASH :: u32(1)

role_overlap_result_hash :: proc(
	source_geometry_hash: contracts.Content_Hash,
	process_hash: contracts.Content_Hash,
	layer_ids: []contracts.Stable_ID,
	sources: []Role_Overlap_Source,
	process: profiles.Resolved_Process_Profile,
	provider: polygon.Polygon_Provider,
	result: Role_Overlap_Result,
	limits := DEFAULT_ROLE_OVERLAP_LIMITS,
	allocator := context.allocator,
) -> (contracts.Content_Hash, bool) {
	expected, expected_error := role_overlap_resolve(
		layer_ids,
		sources,
		process,
		provider,
		result.fill_rule,
		limits,
		allocator,
	)
	if expected_error != .None {return {}, false}
	defer role_overlap_result_destroy(&expected, allocator)
	if result.policy != expected.policy ||
	   result.fill_rule != expected.fill_rule ||
	   result.fully_removed_mask_count !=
		expected.fully_removed_mask_count ||
	   result.source_area_2 != expected.source_area_2 ||
	   result.output_area_2 != expected.output_area_2 ||
	   result.removed_area_2 != expected.removed_area_2 ||
	   len(result.layers) != len(expected.layers) ||
	   len(result.masks) != len(expected.masks) ||
	   len(result.paths) != len(expected.paths) ||
	   len(result.points) != len(expected.points) {
		return {}, false
	}
	for layer, layer_index in result.layers {
		if layer != expected.layers[layer_index] {
			return {}, false
		}
	}
	for mask, mask_index in result.masks {
		if mask != expected.masks[mask_index] {
			return {}, false
		}
	}
	for path, path_index in result.paths {
		if path != expected.paths[path_index] {
			return {}, false
		}
	}
	for point, point_index in result.points {
		if point != expected.points[point_index] {
			return {}, false
		}
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/role-overlap",
		SCHEMA_VERSION_ROLE_OVERLAP_HASH,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		source_geometry_hash,
	)
	contracts.canonical_hash_append_content_hash(&hash, process_hash)
	contracts.canonical_hash_append_u8(&hash, u8(result.policy))
	contracts.canonical_hash_append_u8(&hash, u8(result.fill_rule))
	contracts.canonical_hash_append_u64(
		&hash,
		result.fully_removed_mask_count,
	)
	contracts.canonical_hash_append_i128(&hash, result.source_area_2)
	contracts.canonical_hash_append_i128(&hash, result.output_area_2)
	contracts.canonical_hash_append_i128(&hash, result.removed_area_2)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.layers)))
	for layer in result.layers {
		contracts.canonical_hash_append_u64(&hash, layer.mask_offset)
		contracts.canonical_hash_append_u32(&hash, layer.mask_count)
		contracts.canonical_hash_append_u64(&hash, layer.path_offset)
		contracts.canonical_hash_append_u32(&hash, layer.path_count)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.masks)))
	for mask in result.masks {
		contracts.canonical_hash_append_stable_id(&hash, mask.stable_id)
		contracts.canonical_hash_append_stable_id(&hash, mask.source_id)
		contracts.canonical_hash_append_u32(&hash, mask.source_index)
		contracts.canonical_hash_append_stable_id(&hash, mask.layer_id)
		contracts.canonical_hash_append_u32(&hash, mask.layer_index)
		contracts.canonical_hash_append_u8(&hash, u8(mask.role))
		contracts.canonical_hash_append_u8(&hash, mask.priority)
		contracts.canonical_hash_append_u64(&hash, mask.path_offset)
		contracts.canonical_hash_append_u32(&hash, mask.path_count)
		contracts.canonical_hash_append_u64(&hash, mask.point_offset)
		contracts.canonical_hash_append_u32(&hash, mask.point_count)
		contracts.canonical_hash_append_i128(&hash, mask.source_area_2)
		contracts.canonical_hash_append_i128(&hash, mask.output_area_2)
		contracts.canonical_hash_append_i128(&hash, mask.removed_area_2)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.paths)))
	for path in result.paths {
		contracts.canonical_hash_append_stable_id(&hash, path.stable_id)
		contracts.canonical_hash_append_stable_id(&hash, path.mask_id)
		contracts.canonical_hash_append_u32(
			&hash,
			path.mask_path_index,
		)
		contracts.canonical_hash_append_u64(&hash, path.point_offset)
		contracts.canonical_hash_append_u32(&hash, path.point_count)
		contracts.canonical_hash_append_i128(&hash, path.signed_area_2)
		contracts.canonical_hash_append_u8(&hash, u8(path.winding))
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.points)))
	for point in result.points {
		contracts.canonical_hash_append_i64(&hash, i64(point.x))
		contracts.canonical_hash_append_i64(&hash, i64(point.y))
	}
	return contracts.canonical_hash_final(&hash), true
}
