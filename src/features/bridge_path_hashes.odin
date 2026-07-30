package features

import contracts "../contracts"
import profiles "../profiles"

SCHEMA_VERSION_BRIDGE_PATH_HASH :: u32(1)

bridge_path_result_hash :: proc(
	bridge_evidence_hash: contracts.Content_Hash,
	bridge_direction_hash: contracts.Content_Hash,
	process_hash: contracts.Content_Hash,
	evidence: Bridge_Evidence_Result,
	directions: Bridge_Direction_Result,
	process: profiles.Resolved_Process_Profile,
	result: Bridge_Path_Result,
	limits := DEFAULT_BRIDGE_PATH_LIMITS,
	allocator := context.allocator,
) -> (contracts.Content_Hash, bool) {
	expected, expected_error := bridge_paths_generate(
		evidence,
		directions,
		process,
		limits,
		allocator,
	)
	if expected_error != .None {return {}, false}
	defer bridge_path_result_destroy(&expected, allocator)
	if result.spacing != expected.spacing ||
	   result.phase != expected.phase ||
	   result.direction_scale != expected.direction_scale ||
	   result.scanline_count != expected.scanline_count ||
	   result.skipped_unanchored_count !=
	    expected.skipped_unanchored_count ||
	   len(result.layers) != len(expected.layers) ||
	   len(result.paths) != len(expected.paths) ||
	   len(result.hits) != len(expected.hits) {
		return {}, false
	}
	for layer, layer_index in result.layers {
		if layer != expected.layers[layer_index] {
			return {}, false
		}
	}
	for path, path_index in result.paths {
		if path != expected.paths[path_index] {
			return {}, false
		}
	}
	for hit, hit_index in result.hits {
		if hit != expected.hits[hit_index] {
			return {}, false
		}
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/bridge-paths",
		SCHEMA_VERSION_BRIDGE_PATH_HASH,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		bridge_evidence_hash,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		bridge_direction_hash,
	)
	contracts.canonical_hash_append_content_hash(&hash, process_hash)
	contracts.canonical_hash_append_i64(&hash, i64(result.spacing))
	contracts.canonical_hash_append_i64(&hash, i64(result.phase))
	contracts.canonical_hash_append_i64(&hash, result.direction_scale)
	contracts.canonical_hash_append_u64(&hash, result.scanline_count)
	contracts.canonical_hash_append_u64(
		&hash,
		result.skipped_unanchored_count,
	)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.layers)))
	for layer in result.layers {
		contracts.canonical_hash_append_u64(&hash, layer.path_offset)
		contracts.canonical_hash_append_u32(&hash, layer.path_count)
		contracts.canonical_hash_append_u64(&hash, layer.hit_offset)
		contracts.canonical_hash_append_u32(&hash, layer.hit_count)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.paths)))
	for path in result.paths {
		contracts.canonical_hash_append_stable_id(&hash, path.stable_id)
		contracts.canonical_hash_append_stable_id(
			&hash,
			path.path_set_id,
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			path.evidence_mask_id,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			path.evidence_mask_index,
		)
		contracts.canonical_hash_append_stable_id(&hash, path.region_id)
		contracts.canonical_hash_append_u32(&hash, path.region_index)
		contracts.canonical_hash_append_u32(&hash, path.layer_index)
		contracts.canonical_hash_append_stable_id(
			&hash,
			path.candidate_id,
		)
		contracts.canonical_hash_append_u32(&hash, path.candidate_index)
		contracts.canonical_hash_append_u8(&hash, u8(path.role))
		contracts.canonical_hash_append_i64(&hash, i64(path.angle))
		contracts.canonical_hash_append_i64(&hash, path.direction_x)
		contracts.canonical_hash_append_i64(&hash, path.direction_y)
		contracts.canonical_hash_append_u64(
			&hash,
			path.mask_path_index,
		)
		contracts.canonical_hash_append_u64(
			&hash,
			path.scanline_index,
		)
		contracts.canonical_hash_append_i128(
			&hash,
			path.line_coordinate_scaled,
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(path.line_width),
		)
		contracts.canonical_hash_append_i64(&hash, i64(path.point_a.x))
		contracts.canonical_hash_append_i64(&hash, i64(path.point_a.y))
		contracts.canonical_hash_append_i64(&hash, i64(path.point_b.x))
		contracts.canonical_hash_append_i64(&hash, i64(path.point_b.y))
		contracts.canonical_hash_append_u64(&hash, path.hit_offset)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.hits)))
	for hit in result.hits {
		contracts.canonical_hash_append_u32(
			&hash,
			hit.boundary_path_index,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			hit.boundary_edge_index,
		)
		contracts.canonical_hash_append_i128(&hash, hit.x_numerator)
		contracts.canonical_hash_append_i128(&hash, hit.y_numerator)
		contracts.canonical_hash_append_i128(&hash, hit.denominator)
		contracts.canonical_hash_append_i64(&hash, i64(hit.point.x))
		contracts.canonical_hash_append_i64(&hash, i64(hit.point.y))
		bridge_direction_hash_append_u128(
			&hash,
			hit.error_x_numerator,
		)
		bridge_direction_hash_append_u128(
			&hash,
			hit.error_y_numerator,
		)
	}
	return contracts.canonical_hash_final(&hash), true
}
