package features

import contracts "../contracts"
import geometry "../geometry"

SCHEMA_VERSION_PATH_PLAN_HASH :: u32(1)

path_plan_result_hash :: proc(
	perimeter_hash, infill_hash: contracts.Content_Hash,
	result: Path_Plan_Result,
) -> (contracts.Content_Hash, bool) {
	if geometry.point_2_validate({
		result.config.start.x,
		result.config.start.y,
	}) != .None ||
	   (result.topology_policy != .Strict_Printable &&
	    result.topology_policy != .Diagnostic_Closed_Regions) {
		return {}, false
	}
	expected_path_offset: u64
	expected_move_offset: u64
	for layer, layer_index in result.layers {
		if layer.path_offset != expected_path_offset ||
		   layer.move_offset != expected_move_offset ||
		   layer.path_offset+u64(layer.path_count) >
		   	u64(len(result.paths)) ||
		   layer.move_offset+u64(layer.move_count) >
		   	u64(len(result.moves)) {
			return {}, false
		}
		path_start := int(layer.path_offset)
		path_end := path_start+int(layer.path_count)
		for path in result.paths[path_start:path_end] {
			if path.layer_index != u32(layer_index) {
				return {}, false
			}
		}
		expected_path_offset += u64(layer.path_count)
		expected_move_offset += u64(layer.move_count)
	}
	if expected_path_offset != u64(len(result.paths)) ||
	   expected_move_offset != u64(len(result.moves)) {
		return {}, false
	}

	expected_path_move_offset: u64
	travel_count: u64
	extrude_count: u64
	current := result.config.start
	previous_region_index: u32
	previous_source_kind: Planned_Source_Kind
	for path, path_index in result.paths {
		if path.stable_id == contracts.INVALID_STABLE_ID ||
		   path.source_id == contracts.INVALID_STABLE_ID ||
		   path.region_id == contracts.INVALID_STABLE_ID ||
		   path.stable_id != contracts.stable_id_child(
		   	path.source_id,
		   	.Path,
		   	0,
		   ) ||
		   path.move_offset != expected_path_move_offset ||
		   path.move_count == 0 ||
		   path.move_offset+u64(path.move_count) >
		   	u64(len(result.moves)) ||
		   (path.source_kind != .Perimeter &&
		    path.source_kind != .Infill) {
			return {}, false
		}
		if path_index > 0 {
			if path.region_index < previous_region_index ||
			   path.region_index == previous_region_index &&
			   	previous_source_kind == .Infill &&
			   	path.source_kind == .Perimeter {
				return {}, false
			}
		}
		move_start := int(path.move_offset)
		move_end := move_start+int(path.move_count)
		path_moves := result.moves[move_start:move_end]
		move_index := 0
		if path_moves[0].kind == .Travel {
			travel := path_moves[0]
			if travel.source_edge_index != max(u32) ||
			   travel.stable_id != contracts.stable_id_child(
			   	path.stable_id,
			   	.Path,
			   	u64(1)<<63,
			   ) ||
			   travel.point_a != current ||
			   travel.point_a == travel.point_b ||
			   geometry.point_2_validate({
			   	travel.point_a.x,
			   	travel.point_a.y,
			   }) != .None ||
			   geometry.point_2_validate({
			   	travel.point_b.x,
			   	travel.point_b.y,
			   }) != .None {
				return {}, false
			}
			current = travel.point_b
			travel_count += 1
			move_index = 1
		}
		if move_index >= len(path_moves) {return {}, false}
		first_extrusion_start := path_moves[move_index].point_a
		if first_extrusion_start != current {
			return {}, false
		}
		extrusions_in_path := 0
		for move in path_moves[move_index:] {
			if move.kind != .Extrude ||
			   move.path_id != path.stable_id ||
			   move.point_a != current ||
			   move.point_a == move.point_b ||
			   geometry.point_2_validate({
			   	move.point_a.x,
			   	move.point_a.y,
			   }) != .None ||
			   geometry.point_2_validate({
			   	move.point_b.x,
			   	move.point_b.y,
			   }) != .None ||
			   move.stable_id != contracts.stable_id_child(
			   	path.stable_id,
			   	.Path,
			   	u64(move.source_edge_index),
			   ) {
				return {}, false
			}
			current = move.point_b
			extrusions_in_path += 1
			extrude_count += 1
		}
		if path.closed {
			if path.source_kind != .Perimeter ||
			   path.reversed ||
			   extrusions_in_path < 3 ||
			   current != first_extrusion_start {
				return {}, false
			}
		} else {
			if path.source_kind != .Infill ||
			   extrusions_in_path != 1 ||
			   path.start_index > 1 {
				return {}, false
			}
		}
		for move in path_moves {
			if move.path_id != path.stable_id {return {}, false}
		}
		expected_path_move_offset += u64(path.move_count)
		previous_region_index = path.region_index
		previous_source_kind = path.source_kind
	}
	if expected_path_move_offset != u64(len(result.moves)) ||
	   travel_count != result.travel_move_count ||
	   extrude_count != result.extrude_move_count {
		return {}, false
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/path-plan",
		SCHEMA_VERSION_PATH_PLAN_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, perimeter_hash)
	contracts.canonical_hash_append_content_hash(&hash, infill_hash)
	contracts.canonical_hash_append_i64(&hash, i64(result.config.start.x))
	contracts.canonical_hash_append_i64(&hash, i64(result.config.start.y))
	contracts.canonical_hash_append_u8(
		&hash,
		u8(result.config.inner_perimeters_first),
	)
	contracts.canonical_hash_append_u8(
		&hash,
		u8(result.topology_policy),
	)
	contracts.canonical_hash_append_u64(&hash, result.travel_move_count)
	contracts.canonical_hash_append_u64(&hash, result.extrude_move_count)
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
		contracts.canonical_hash_append_stable_id(&hash, path.source_id)
		contracts.canonical_hash_append_u8(&hash, u8(path.source_kind))
		contracts.canonical_hash_append_u32(&hash, path.source_index)
		contracts.canonical_hash_append_stable_id(&hash, path.region_id)
		contracts.canonical_hash_append_u32(&hash, path.region_index)
		contracts.canonical_hash_append_u32(&hash, path.layer_index)
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
		contracts.canonical_hash_append_u32(
			&hash,
			move.source_edge_index,
		)
		contracts.canonical_hash_append_i64(&hash, i64(move.point_a.x))
		contracts.canonical_hash_append_i64(&hash, i64(move.point_a.y))
		contracts.canonical_hash_append_i64(&hash, i64(move.point_b.x))
		contracts.canonical_hash_append_i64(&hash, i64(move.point_b.y))
	}
	return contracts.canonical_hash_final(&hash), true
}
