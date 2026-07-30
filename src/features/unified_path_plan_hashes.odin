package features

import contracts "../contracts"

SCHEMA_VERSION_UNIFIED_PATH_PLAN_HASH :: u32(2)

unified_path_plan_result_hash :: proc(
	source_paths_hash: contracts.Content_Hash,
	layer_ids: []contracts.Stable_ID,
	sources: []Unified_Path_Source,
	result: Unified_Path_Plan_Result,
	limits := DEFAULT_UNIFIED_PATH_PLAN_LIMITS,
	allocator := context.allocator,
) -> (contracts.Content_Hash, bool) {
	expected, expected_error := unified_path_plan_build(
		layer_ids,
		sources,
		result.config,
		limits,
		allocator,
	)
	if expected_error != .None {return {}, false}
	defer unified_path_plan_result_destroy(&expected, allocator)
	if result.config != expected.config ||
	   result.travel_move_count != expected.travel_move_count ||
	   result.extrude_move_count != expected.extrude_move_count ||
	   len(result.layers) != len(expected.layers) ||
	   len(result.paths) != len(expected.paths) ||
	   len(result.moves) != len(expected.moves) {
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
	for move, move_index in result.moves {
		if move != expected.moves[move_index] {
			return {}, false
		}
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/unified-path-plan",
		SCHEMA_VERSION_UNIFIED_PATH_PLAN_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, source_paths_hash)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.config.start.x),
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.config.start.y),
	)
	contracts.canonical_hash_append_u8(&hash, u8(result.config.seam))
	contracts.canonical_hash_append_u8(
		&hash,
		u8(result.config.seam_visibility),
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.travel_move_count,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.extrude_move_count,
	)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.layers)))
	for layer in result.layers {
		contracts.canonical_hash_append_u64(&hash, layer.path_offset)
		contracts.canonical_hash_append_u32(&hash, layer.path_count)
		contracts.canonical_hash_append_u64(&hash, layer.move_offset)
		contracts.canonical_hash_append_u32(&hash, layer.move_count)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.paths)))
	for path in result.paths {
		contracts.canonical_hash_append_stable_id(&hash, path.stable_id)
		contracts.canonical_hash_append_stable_id(
			&hash,
			path.path_set_id,
		)
		contracts.canonical_hash_append_stable_id(&hash, path.source_id)
		contracts.canonical_hash_append_u8(&hash, u8(path.source_kind))
		contracts.canonical_hash_append_u32(&hash, path.source_index)
		contracts.canonical_hash_append_u64(&hash, path.source_order)
		contracts.canonical_hash_append_stable_id(&hash, path.layer_id)
		contracts.canonical_hash_append_u32(&hash, path.layer_index)
		contracts.canonical_hash_append_u8(&hash, u8(path.role))
		contracts.canonical_hash_append_u8(&hash, path.priority)
		contracts.canonical_hash_append_u32(&hash, path.start_index)
		contracts.canonical_hash_append_u8(&hash, u8(path.reversed))
		contracts.canonical_hash_append_u8(&hash, u8(path.closed))
		contracts.canonical_hash_append_u64(&hash, path.move_offset)
		contracts.canonical_hash_append_u32(&hash, path.move_count)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.moves)))
	for move in result.moves {
		contracts.canonical_hash_append_stable_id(&hash, move.stable_id)
		contracts.canonical_hash_append_stable_id(&hash, move.path_id)
		contracts.canonical_hash_append_u8(&hash, u8(move.kind))
		contracts.canonical_hash_append_u8(&hash, u8(move.role))
		contracts.canonical_hash_append_u32(
			&hash,
			move.source_edge_index,
		)
		contracts.canonical_hash_append_i64(&hash, i64(move.point_a.x))
		contracts.canonical_hash_append_i64(&hash, i64(move.point_a.y))
		contracts.canonical_hash_append_i64(&hash, i64(move.point_b.x))
		contracts.canonical_hash_append_i64(&hash, i64(move.point_b.y))
		contracts.canonical_hash_append_i64(
			&hash,
			i64(move.line_width_a),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(move.line_width_b),
		)
	}
	return contracts.canonical_hash_final(&hash), true
}
