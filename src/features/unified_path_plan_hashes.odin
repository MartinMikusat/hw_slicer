package features

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"

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
	return unified_path_plan_result_content_hash(
		source_paths_hash,
		result,
	)
}

unified_path_plan_result_content_hash :: proc(
	source_paths_hash: contracts.Content_Hash,
	result: Unified_Path_Plan_Result,
) -> (contracts.Content_Hash, bool) {
	if !unified_path_plan_result_structurally_valid(result) {
		return {}, false
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

unified_path_plan_result_structurally_valid :: proc(
	result: Unified_Path_Plan_Result,
) -> bool {
	if geometry.point_2_validate({
		result.config.start.x,
		result.config.start.y,
	}) != .None ||
	   result.config.seam != .Deterministic_Cost ||
	   result.config.seam_visibility != .Rear_Maximum_Y ||
	   u64(len(result.layers)) > u64(max(u32)) ||
	   result.travel_move_count > max(u64)-result.extrude_move_count ||
	   result.travel_move_count+result.extrude_move_count !=
		u64(len(result.moves)) {
		return false
	}
	expected_path_offset: u64
	expected_move_offset: u64
	travel_move_count: u64
	extrude_move_count: u64
	current := result.config.start
	for layer, layer_index in result.layers {
		if layer.path_offset != expected_path_offset ||
		   layer.move_offset != expected_move_offset ||
		   layer.path_offset > max(u64)-u64(layer.path_count) ||
		   layer.move_offset > max(u64)-u64(layer.move_count) ||
		   layer.path_offset+u64(layer.path_count) >
			u64(len(result.paths)) ||
		   layer.move_offset+u64(layer.move_count) >
			u64(len(result.moves)) {
			return false
		}
		path_start := int(layer.path_offset)
		path_end := path_start+int(layer.path_count)
		move_end := layer.move_offset+u64(layer.move_count)
		path_move_offset := layer.move_offset
		previous_priority: u8
		previous_source_order: u64
		previous_source_id := contracts.INVALID_STABLE_ID
		layer_id := contracts.INVALID_STABLE_ID
		for path in result.paths[path_start:path_end] {
			priority, priority_ok :=
				profiles.printable_role_priority(path.role)
			if !priority_ok ||
			   priority != path.priority ||
			   !unified_path_source_kind_valid(
					path.source_kind,
					path.role,
			   ) ||
			   path.stable_id == contracts.INVALID_STABLE_ID ||
			   path.path_set_id == contracts.INVALID_STABLE_ID ||
			   path.source_id == contracts.INVALID_STABLE_ID ||
			   path.layer_id == contracts.INVALID_STABLE_ID ||
			   path.layer_index != u32(layer_index) ||
			   path.path_set_id != contracts.stable_id_child(
					path.source_id,
					.Feature,
					0,
			   ) ||
			   path.stable_id != contracts.stable_id_child(
					path.path_set_id,
					.Path,
					0,
			   ) ||
			   path.move_count == 0 ||
			   path.move_offset != path_move_offset ||
			   path.move_offset > max(u64)-u64(path.move_count) ||
			   path.move_offset+u64(path.move_count) > move_end {
				return false
			}
			if layer_id == contracts.INVALID_STABLE_ID {
				layer_id = path.layer_id
			} else if path.layer_id != layer_id {
				return false
			}
			if previous_source_id != contracts.INVALID_STABLE_ID {
				if path.priority < previous_priority ||
				   path.priority == previous_priority &&
					path.source_order < previous_source_order ||
				   path.priority == previous_priority &&
					path.source_order == previous_source_order &&
					path.source_id <= previous_source_id {
					return false
				}
			}
			move_start := int(path.move_offset)
			move_path_end := move_start+int(path.move_count)
			if !unified_path_plan_path_structurally_valid(
				path,
				result.moves[move_start:move_path_end],
				&current,
				&travel_move_count,
				&extrude_move_count,
			) {
				return false
			}
			path_move_offset += u64(path.move_count)
			previous_priority = path.priority
			previous_source_order = path.source_order
			previous_source_id = path.source_id
		}
		if path_move_offset != move_end {return false}
		expected_path_offset += u64(layer.path_count)
		expected_move_offset += u64(layer.move_count)
	}
	return expected_path_offset == u64(len(result.paths)) &&
		expected_move_offset == u64(len(result.moves)) &&
		travel_move_count == result.travel_move_count &&
		extrude_move_count == result.extrude_move_count
}

unified_path_plan_path_structurally_valid :: proc(
	path: Unified_Planned_Path,
	moves: []Unified_Planned_Move,
	current: ^polygon.Polygon_Point,
	travel_move_count, extrude_move_count: ^u64,
) -> bool {
	move_index := 0
	if moves[0].kind == .Travel {
		travel := moves[0]
		if travel.stable_id != contracts.stable_id_child(
			path.stable_id,
			.Path,
			u64(1)<<63,
		   ) ||
		   travel.path_id != path.stable_id ||
		   travel.role != .Invalid ||
		   travel.source_edge_index != max(u32) ||
		   travel.point_a != current^ ||
		   travel.point_a == travel.point_b ||
		   travel.line_width_a != 0 ||
		   travel.line_width_b != 0 ||
		   geometry.point_2_validate({
				travel.point_a.x,
				travel.point_a.y,
		   }) != .None ||
		   geometry.point_2_validate({
				travel.point_b.x,
				travel.point_b.y,
		   }) != .None {
			return false
		}
		travel_move_count^ += 1
		move_index = 1
	}
	if move_index >= len(moves) {return false}
	extrusions := moves[move_index:]
	if path.closed {
		if path.reversed ||
		   len(extrusions) < 3 ||
		   u64(path.start_index) >= u64(len(extrusions)) {
			return false
		}
	} else {
		if path.reversed {
			if u64(path.start_index) != u64(len(extrusions)) {
				return false
			}
		} else if path.start_index != 0 {
			return false
		}
	}
	if moves[0].kind == .Travel {
		if moves[0].point_b != extrusions[0].point_a {
			return false
		}
	} else if current^ != extrusions[0].point_a {
		return false
	}
	first := extrusions[0]
	previous := first
	for move, extrusion_index in extrusions {
		expected_edge_index := u32(extrusion_index)
		if path.closed {
			expected_edge_index = u32(
				(u64(path.start_index)+u64(extrusion_index))%
					u64(len(extrusions)),
			)
		} else if path.reversed {
			expected_edge_index =
				u32(len(extrusions)-1-extrusion_index)
		}
		if move.kind != .Extrude ||
		   move.path_id != path.stable_id ||
		   move.role != path.role ||
		   move.source_edge_index != expected_edge_index ||
		   move.stable_id != contracts.stable_id_child(
				path.stable_id,
				.Path,
				u64(expected_edge_index),
		   ) ||
		   move.point_a == move.point_b ||
		   geometry.point_2_validate({
				move.point_a.x,
				move.point_a.y,
		   }) != .None ||
		   geometry.point_2_validate({
				move.point_b.x,
				move.point_b.y,
		   }) != .None ||
		   i64(move.line_width_a) <= 0 ||
		   i64(move.line_width_b) <= 0 ||
		   i64(move.line_width_a) >
			geometry.MAX_PLANAR_COORDINATE_UM ||
		   i64(move.line_width_b) >
			geometry.MAX_PLANAR_COORDINATE_UM {
			return false
		}
		if extrusion_index > 0 &&
		   (move.point_a != previous.point_b ||
		    move.line_width_a != previous.line_width_b) {
			return false
		}
		previous = move
		extrude_move_count^ += 1
	}
	if path.closed &&
	   (previous.point_b != first.point_a ||
	    previous.line_width_b != first.line_width_a) {
		return false
	}
	current^ = previous.point_b
	return true
}
