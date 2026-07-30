package features

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"

SCHEMA_VERSION_PERIMETER_HASH :: u32(1)

perimeter_result_hash :: proc(
	region_hash: contracts.Content_Hash,
	result: Perimeter_Result,
) -> (contracts.Content_Hash, bool) {
	if !perimeter_config_valid(result.config) ||
	   result.config.arc_tolerance == 0 &&
	   	transmute(u64)result.config.arc_tolerance != 0 {
		return {}, false
	}
	expected_group_offset: u64
	expected_layer_path_offset: u64
	for layer, layer_index in result.layers {
		if layer.group_offset != expected_group_offset ||
		   layer.path_offset != expected_layer_path_offset ||
		   layer.group_offset > max(u64)-u64(layer.group_count) ||
		   layer.group_offset+u64(layer.group_count) >
		   	u64(len(result.groups)) ||
		   layer.path_offset > max(u64)-u64(layer.path_count) ||
		   layer.path_offset+u64(layer.path_count) >
		   	u64(len(result.paths)) {
			return {}, false
		}
		group_start := int(layer.group_offset)
		group_end := group_start+int(layer.group_count)
		for group in result.groups[group_start:group_end] {
			if group.layer_index != u32(layer_index) {
				return {}, false
			}
		}
		path_start := int(layer.path_offset)
		path_end := path_start+int(layer.path_count)
		for path in result.paths[path_start:path_end] {
			if path.layer_index != u32(layer_index) {
				return {}, false
			}
		}
		expected_group_offset += u64(layer.group_count)
		expected_layer_path_offset += u64(layer.path_count)
	}
	if expected_group_offset != u64(len(result.groups)) ||
	   expected_layer_path_offset != u64(len(result.paths)) {
		return {}, false
	}

	expected_path_offset: u64
	previous_region_id: contracts.Stable_ID
	previous_region_index: u32
	previous_perimeter_index: u32
	for group, group_index in result.groups {
		if group.region_id == contracts.INVALID_STABLE_ID ||
		   group.path_offset != expected_path_offset ||
		   group.path_offset > max(u64)-u64(group.path_count) ||
		   group.path_offset+u64(group.path_count) >
		   	u64(len(result.paths)) {
			return {}, false
		}
		if group_index > 0 {
			if group.region_index < previous_region_index ||
			   group.region_index == previous_region_index &&
			   	(group.region_id != previous_region_id ||
			   	 group.perimeter_index !=
			   	 	previous_perimeter_index+1) ||
			   group.region_index > previous_region_index &&
			   	(group.region_index != previous_region_index+1 ||
			   	 group.perimeter_index != 0 ||
			   	 previous_perimeter_index != result.config.count-1) {
				return {}, false
			}
		} else if group.region_index != 0 ||
		          group.perimeter_index != 0 {
			return {}, false
		}
		if group.perimeter_index >= result.config.count {
			return {}, false
		}
		expected_delta, delta_ok :=
			perimeter_delta(result.config, group.perimeter_index)
		if !delta_ok || group.delta != expected_delta {
			return {}, false
		}
		path_start := int(group.path_offset)
		path_end := path_start+int(group.path_count)
		previous_points: []polygon.Polygon_Point
		for path, local_path_index in result.paths[path_start:path_end] {
			if path.region_id != group.region_id ||
			   path.region_index != group.region_index ||
			   path.layer_index != group.layer_index ||
			   path.perimeter_index != group.perimeter_index ||
			   path.group_path_index != u32(local_path_index) ||
			   path.point_count < 3 ||
			   path.point_offset > max(u64)-u64(path.point_count) ||
			   path.point_offset+u64(path.point_count) >
			   	u64(len(result.points)) {
				return {}, false
			}
			ordinal, ordinal_ok := feature_perimeter_ordinal(
				path.perimeter_index,
				path.group_path_index,
			)
			if !ordinal_ok ||
			   path.stable_id != contracts.stable_id_child(
				path.region_id,
				.Feature,
				ordinal,
			) {
				return {}, false
			}
			point_start := int(path.point_offset)
			point_end := point_start+int(path.point_count)
			points := result.points[point_start:point_end]
			if polygon.polygon_minimum_rotation(points) != 0 ||
			   polygon.polygon_path_area_2(points) !=
			   	path.signed_area_2 ||
			   path.signed_area_2 == 0 ||
			   path.signed_area_2 < 0 &&
			   	path.winding != .Negative ||
			   path.signed_area_2 > 0 &&
			   	path.winding != .Positive {
				return {}, false
			}
			previous := points[len(points)-1]
			for point in points {
				if point == previous ||
				   geometry.point_2_validate({point.x, point.y}) !=
				   	.None {
					return {}, false
				}
				previous = point
			}
			if local_path_index > 0 &&
			   polygon.polygon_path_slice_less(
			   	points,
			   	previous_points,
			   ) {
				return {}, false
			}
			previous_points = points
		}
		expected_path_offset += u64(group.path_count)
		previous_region_id = group.region_id
		previous_region_index = group.region_index
		previous_perimeter_index = group.perimeter_index
	}
	if expected_path_offset != u64(len(result.paths)) {
		return {}, false
	}
	expected_point_offset: u64
	for path in result.paths {
		if path.point_offset != expected_point_offset {
			return {}, false
		}
		expected_point_offset += u64(path.point_count)
	}
	if expected_point_offset != u64(len(result.points)) {
		return {}, false
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/perimeters",
		SCHEMA_VERSION_PERIMETER_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, region_hash)
	contracts.canonical_hash_append_u32(&hash, result.config.count)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.config.line_width),
	)
	contracts.canonical_hash_append_u8(
		&hash,
		u8(result.config.topology_policy),
	)
	contracts.canonical_hash_append_u8(
		&hash,
		u8(result.config.join_type),
	)
	contracts.canonical_hash_append_f64_bits(
		&hash,
		result.config.miter_limit,
	)
	contracts.canonical_hash_append_f64_bits(
		&hash,
		result.config.arc_tolerance,
	)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.layers)))
	for layer in result.layers {
		contracts.canonical_hash_append_u64(&hash, layer.group_offset)
		contracts.canonical_hash_append_u32(&hash, layer.group_count)
		contracts.canonical_hash_append_u64(&hash, layer.path_offset)
		contracts.canonical_hash_append_u32(&hash, layer.path_count)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.groups)))
	for group in result.groups {
		contracts.canonical_hash_append_stable_id(&hash, group.region_id)
		contracts.canonical_hash_append_u32(&hash, group.region_index)
		contracts.canonical_hash_append_u32(&hash, group.layer_index)
		contracts.canonical_hash_append_u32(
			&hash,
			group.perimeter_index,
		)
		contracts.canonical_hash_append_i64(&hash, i64(group.delta))
		contracts.canonical_hash_append_u64(&hash, group.path_offset)
		contracts.canonical_hash_append_u32(&hash, group.path_count)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.paths)))
	for path in result.paths {
		contracts.canonical_hash_append_stable_id(&hash, path.stable_id)
		contracts.canonical_hash_append_stable_id(&hash, path.region_id)
		contracts.canonical_hash_append_u32(&hash, path.region_index)
		contracts.canonical_hash_append_u32(&hash, path.layer_index)
		contracts.canonical_hash_append_u32(
			&hash,
			path.perimeter_index,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			path.group_path_index,
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
