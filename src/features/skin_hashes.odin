package features

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import slicing "../slicing"

SCHEMA_VERSION_SKIN_HASH :: u32(1)

skin_result_hash :: proc(
	surface_hash: contracts.Content_Hash,
	layer_schedule_hash: contracts.Content_Hash,
	layer_heights: []contracts.Micrometres,
	regions: slicing.Region_Result,
	surfaces: Surface_Result,
	result: Skin_Result,
) -> (contracts.Content_Hash, bool) {
	if !skin_config_valid(result.config) ||
	   len(result.layers) != len(regions.layers) ||
	   len(result.layers) != len(surfaces.layers) ||
	   len(result.layers) != len(layer_heights) {
		return {}, false
	}
	for height in layer_heights {
		if i64(height) <= 0 {return {}, false}
	}
	mask_count := u64(len(result.masks))
	if result.bottom_mask_count > mask_count ||
	   result.top_mask_count >
	   	mask_count-result.bottom_mask_count ||
	   result.top_bottom_mask_count >
	   	mask_count-result.bottom_mask_count-result.top_mask_count ||
	   result.bottom_mask_count+result.top_mask_count+
	   	result.top_bottom_mask_count != mask_count {
		return {}, false
	}

	expected_mask_offset: u64
	expected_path_offset: u64
	expected_source_offset: u64
	for layer, layer_index in result.layers {
		if layer.mask_offset != expected_mask_offset ||
		   layer.path_offset != expected_path_offset ||
		   layer.source_reference_offset != expected_source_offset ||
		   layer.mask_offset+u64(layer.mask_count) >
		   	u64(len(result.masks)) ||
		   layer.path_offset+u64(layer.path_count) >
		   	u64(len(result.paths)) ||
		   layer.source_reference_offset+
		   	u64(layer.source_reference_count) >
		   	u64(len(result.source_references)) {
			return {}, false
		}
		mask_start := int(layer.mask_offset)
		mask_end := mask_start+int(layer.mask_count)
		path_count: u64
		source_count: u64
		for mask in result.masks[mask_start:mask_end] {
			if mask.layer_index != u32(layer_index) {
				return {}, false
			}
			path_count += u64(mask.path_count)
			source_count += u64(mask.source_reference_count)
		}
		if path_count != u64(layer.path_count) ||
		   source_count != u64(layer.source_reference_count) {
			return {}, false
		}
		expected_mask_offset += u64(layer.mask_count)
		expected_path_offset += u64(layer.path_count)
		expected_source_offset += u64(layer.source_reference_count)
	}
	if expected_mask_offset != u64(len(result.masks)) ||
	   expected_path_offset != u64(len(result.paths)) ||
	   expected_source_offset != u64(len(result.source_references)) {
		return {}, false
	}

	expected_path_offset = 0
	expected_point_offset: u64
	expected_source_offset = 0
	bottom_count: u64
	top_count: u64
	top_bottom_count: u64
	previous_region_index: u32
	previous_kind: Skin_Kind
	for mask, mask_index in result.masks {
		if u64(mask.region_index) >= u64(len(regions.regions)) {
			return {}, false
		}
		region := regions.regions[mask.region_index]
		ordinal, ordinal_ok := feature_skin_ordinal(mask.kind)
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
		   mask.source_reference_count == 0 ||
		   mask.path_offset != expected_path_offset ||
		   mask.point_offset != expected_point_offset ||
		   mask.source_reference_offset != expected_source_offset ||
		   mask.path_offset+u64(mask.path_count) >
		   	u64(len(result.paths)) ||
		   mask.point_offset+u64(mask.point_count) >
		   	u64(len(result.points)) ||
		   mask.source_reference_offset+
		   	u64(mask.source_reference_count) >
		   	u64(len(result.source_references)) {
			return {}, false
		}
		if mask_index > 0 &&
		   (mask.region_index < previous_region_index ||
		    mask.region_index == previous_region_index &&
		    	mask.kind <= previous_kind) {
			return {}, false
		}
		switch mask.kind {
		case .Bottom:     bottom_count += 1
		case .Top:        top_count += 1
		case .Top_Bottom: top_bottom_count += 1
		case .Invalid:    return {}, false
		}
		if !skin_source_references_valid(
			mask,
			layer_heights,
			surfaces,
			result.source_references,
			result.config,
		) {
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
		expected_source_offset += u64(mask.source_reference_count)
		previous_region_index = mask.region_index
		previous_kind = mask.kind
	}
	if expected_path_offset != u64(len(result.paths)) ||
	   expected_point_offset != u64(len(result.points)) ||
	   expected_source_offset != u64(len(result.source_references)) ||
	   bottom_count != result.bottom_mask_count ||
	   top_count != result.top_mask_count ||
	   top_bottom_count != result.top_bottom_mask_count {
		return {}, false
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/skin",
		SCHEMA_VERSION_SKIN_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, surface_hash)
	contracts.canonical_hash_append_content_hash(
		&hash,
		layer_schedule_hash,
	)
	contracts.canonical_hash_append_u8(&hash, u8(result.config.fill_rule))
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.config.top.thickness),
	)
	contracts.canonical_hash_append_u32(
		&hash,
		result.config.top.minimum_layers,
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.config.bottom.thickness),
	)
	contracts.canonical_hash_append_u32(
		&hash,
		result.config.bottom.minimum_layers,
	)
	contracts.canonical_hash_append_u64(&hash, u64(len(layer_heights)))
	for height in layer_heights {
		contracts.canonical_hash_append_i64(&hash, i64(height))
	}
	contracts.canonical_hash_append_u64(&hash, result.bottom_mask_count)
	contracts.canonical_hash_append_u64(&hash, result.top_mask_count)
	contracts.canonical_hash_append_u64(
		&hash,
		result.top_bottom_mask_count,
	)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.layers)))
	for layer in result.layers {
		contracts.canonical_hash_append_u64(&hash, layer.mask_offset)
		contracts.canonical_hash_append_u32(&hash, layer.mask_count)
		contracts.canonical_hash_append_u64(&hash, layer.path_offset)
		contracts.canonical_hash_append_u32(&hash, layer.path_count)
		contracts.canonical_hash_append_u64(
			&hash,
			layer.source_reference_offset,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			layer.source_reference_count,
		)
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
		contracts.canonical_hash_append_u64(
			&hash,
			mask.source_reference_offset,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			mask.source_reference_count,
		)
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
	contracts.canonical_hash_append_u64(
		&hash,
		u64(len(result.source_references)),
	)
	for reference in result.source_references {
		contracts.canonical_hash_append_u32(
			&hash,
			reference.surface_mask_index,
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			reference.surface_id,
		)
		contracts.canonical_hash_append_u8(
			&hash,
			u8(reference.surface_kind),
		)
		contracts.canonical_hash_append_u32(
			&hash,
			reference.source_layer_index,
		)
	}
	return contracts.canonical_hash_final(&hash), true
}

skin_source_references_valid :: proc(
	mask: Skin_Mask,
	layer_heights: []contracts.Micrometres,
	surfaces: Surface_Result,
	references: []Skin_Source_Reference,
	config: Skin_Config,
) -> bool {
	start := int(mask.source_reference_offset)
	end := start+int(mask.source_reference_count)
	previous_index: u32
	has_bottom := false
	has_top := false
	for reference, local_index in references[start:end] {
		if u64(reference.surface_mask_index) >=
		   	u64(len(surfaces.masks)) ||
		   local_index > 0 &&
		   	reference.surface_mask_index <= previous_index {
			return false
		}
		surface := surfaces.masks[reference.surface_mask_index]
		if reference.surface_id != surface.stable_id ||
		   reference.surface_kind != surface.kind ||
		   reference.source_layer_index != surface.layer_index {
			return false
		}
		target := config.bottom
		if surface.kind == .Bottom_Exposed {
			has_bottom = true
		} else if surface.kind == .Top_Exposed {
			has_top = true
			target = config.top
		} else {
			return false
		}
		first, last, range_ok := skin_target_layer_range(
			layer_heights,
			surface.layer_index,
			surface.kind,
			target,
		)
		if !range_ok ||
		   mask.layer_index < first ||
		   mask.layer_index > last {
			return false
		}
		previous_index = reference.surface_mask_index
	}
	switch mask.kind {
	case .Bottom:
		return has_bottom && !has_top
	case .Top:
		return has_top && !has_bottom
	case .Top_Bottom:
		return has_bottom && has_top
	case .Invalid:
		return false
	}
	return false
}
