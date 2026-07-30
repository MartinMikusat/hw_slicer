package features

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import slicing "../slicing"

SCHEMA_VERSION_GAP_EVIDENCE_HASH :: u32(1)

gap_evidence_result_hash :: proc(
	region_hash: contracts.Content_Hash,
	perimeter_hash: contracts.Content_Hash,
	regions: slicing.Region_Result,
	perimeters: Perimeter_Result,
	result: Gap_Evidence_Result,
) -> (contracts.Content_Hash, bool) {
	calculated_perimeter_hash, perimeter_ok := perimeter_result_hash(
		region_hash,
		perimeters,
	)
	derived, config_ok := gap_evidence_derived_config(
		perimeters,
		result.config,
	)
	if !perimeter_ok || calculated_perimeter_hash != perimeter_hash ||
	   !config_ok ||
	   result.shell_half_width != derived.shell_half_width ||
	   result.minimum_center_radius != derived.minimum_center_radius ||
	   result.maximum_one_radius != derived.maximum_one_radius ||
	   result.maximum_two_radius != derived.maximum_two_radius ||
	   len(result.layers) != len(regions.layers) {
		return {}, false
	}

	expected_mask_offset: u64
	expected_path_offset: u64
	for layer, layer_index in result.layers {
		if layer.mask_offset != expected_mask_offset ||
		   layer.path_offset != expected_path_offset ||
		   layer.mask_offset+u64(layer.mask_count) >
		   	u64(len(result.masks)) ||
		   layer.path_offset+u64(layer.path_count) >
		   	u64(len(result.paths)) {
			return {}, false
		}
		mask_start := int(layer.mask_offset)
		mask_end := mask_start+int(layer.mask_count)
		path_count: u64
		for mask in result.masks[mask_start:mask_end] {
			if mask.layer_index != u32(layer_index) {
				return {}, false
			}
			path_count += u64(mask.path_count)
		}
		if path_count != u64(layer.path_count) {return {}, false}
		expected_mask_offset += u64(layer.mask_count)
		expected_path_offset += u64(layer.path_count)
	}
	if expected_mask_offset != u64(len(result.masks)) ||
	   expected_path_offset != u64(len(result.paths)) {
		return {}, false
	}

	expected_path_offset = 0
	expected_point_offset: u64
	previous_region_index: u32
	previous_kind: Gap_Evidence_Kind
	for mask, mask_index in result.masks {
		if u64(mask.region_index) >= u64(len(regions.regions)) {
			return {}, false
		}
		region := regions.regions[mask.region_index]
		ordinal, ordinal_ok := feature_gap_evidence_ordinal(mask.kind)
		if !ordinal_ok ||
		   mask.stable_id == contracts.INVALID_STABLE_ID ||
		   mask.region_id != region.stable_id ||
		   mask.layer_index != region.layer_index ||
		   mask.stable_id != contracts.stable_id_child(
		   	region.stable_id,
		   	.Feature,
		   	ordinal,
		   ) ||
		   mask.path_count == 0 ||
		   mask.point_count == 0 ||
		   mask.path_offset != expected_path_offset ||
		   mask.point_offset != expected_point_offset ||
		   mask.path_offset+u64(mask.path_count) >
		   	u64(len(result.paths)) ||
		   mask.point_offset+u64(mask.point_count) >
		   	u64(len(result.points)) {
			return {}, false
		}
		if mask_index > 0 &&
		   (mask.region_index < previous_region_index ||
		    mask.region_index == previous_region_index &&
		    	mask.kind <= previous_kind) {
			return {}, false
		}
		path_start := int(mask.path_offset)
		path_end := path_start+int(mask.path_count)
		mask_point_end := mask.point_offset+u64(mask.point_count)
		previous_points: []polygon.Polygon_Point
		for path, local_path_index in result.paths[path_start:path_end] {
			if path.mask_id != mask.stable_id ||
			   path.mask_path_index != u32(local_path_index) ||
			   path.point_count < 3 ||
			   path.point_offset != expected_point_offset ||
			   path.point_offset+u64(path.point_count) >
			   	mask_point_end ||
			   path.stable_id != contracts.stable_id_child(
			   	mask.stable_id,
			   	.Path,
			   	u64(local_path_index),
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
			expected_point_offset += u64(path.point_count)
		}
		if expected_point_offset != mask_point_end {return {}, false}
		expected_path_offset += u64(mask.path_count)
		previous_region_index = mask.region_index
		previous_kind = mask.kind
	}
	if expected_path_offset != u64(len(result.paths)) ||
	   expected_point_offset != u64(len(result.points)) {
		return {}, false
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/gap-evidence",
		SCHEMA_VERSION_GAP_EVIDENCE_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, region_hash)
	contracts.canonical_hash_append_content_hash(&hash, perimeter_hash)
	contracts.canonical_hash_append_u8(&hash, u8(result.config.fill_rule))
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.config.minimum_line_width),
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.config.maximum_line_width),
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
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.shell_half_width),
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.minimum_center_radius),
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.maximum_one_radius),
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.maximum_two_radius),
	)
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
		contracts.canonical_hash_append_stable_id(&hash, mask.region_id)
		contracts.canonical_hash_append_u32(&hash, mask.region_index)
		contracts.canonical_hash_append_u32(&hash, mask.layer_index)
		contracts.canonical_hash_append_u8(&hash, u8(mask.kind))
		contracts.canonical_hash_append_u64(&hash, mask.path_offset)
		contracts.canonical_hash_append_u32(&hash, mask.path_count)
		contracts.canonical_hash_append_u64(&hash, mask.point_offset)
		contracts.canonical_hash_append_u32(&hash, mask.point_count)
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
