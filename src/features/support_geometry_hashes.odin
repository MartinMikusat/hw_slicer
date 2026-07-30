package features

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"
import slicing "../slicing"

SCHEMA_VERSION_SUPPORT_GEOMETRY_HASH :: u32(1)

support_geometry_result_hash :: proc(
	schedule_hash: contracts.Content_Hash,
	region_hash: contracts.Content_Hash,
	support_demand_hash: contracts.Content_Hash,
	process_hash: contracts.Content_Hash,
	schedule: slicing.Fixed_Layer_Schedule,
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	demand: Support_Demand_Result,
	process: profiles.Resolved_Process_Profile,
	provider: polygon.Polygon_Provider,
	result: Support_Geometry_Result,
	limits := DEFAULT_SUPPORT_GEOMETRY_LIMITS,
	allocator := context.allocator,
) -> (contracts.Content_Hash, bool) {
	calculated_schedule_hash, schedule_ok :=
		slicing.fixed_layer_schedule_hash(schedule)
	calculated_region_hash, regions_ok :=
		slicing.region_result_hash({}, topology, regions)
	if !schedule_ok || calculated_schedule_hash != schedule_hash ||
	   !regions_ok || calculated_region_hash != region_hash {
		return {}, false
	}
	expected, expected_error := support_geometry_build(
		schedule,
		topology,
		regions,
		demand,
		process,
		provider,
		limits,
		allocator,
	)
	if expected_error != .None {return {}, false}
	defer support_geometry_result_destroy(&expected, allocator)
	if result.config != expected.config ||
	   result.mode != expected.mode ||
	   result.clearance_xy != expected.clearance_xy ||
	   result.clearance_z != expected.clearance_z ||
	   result.expansion != expected.expansion ||
	   result.interface_layers != expected.interface_layers ||
	   result.regular_mask_count != expected.regular_mask_count ||
	   result.interface_mask_count != expected.interface_mask_count ||
	   result.unresolved_demand_count !=
		expected.unresolved_demand_count ||
	   len(result.layers) != len(expected.layers) ||
	   len(result.masks) != len(expected.masks) ||
	   len(result.paths) != len(expected.paths) ||
	   len(result.points) != len(expected.points) ||
	   len(result.source_demand_references) !=
		len(expected.source_demand_references) {
		return {}, false
	}
	for layer, layer_index in result.layers {
		if layer != expected.layers[layer_index] {return {}, false}
	}
	for mask, mask_index in result.masks {
		if mask != expected.masks[mask_index] {return {}, false}
	}
	for path, path_index in result.paths {
		if path != expected.paths[path_index] {return {}, false}
	}
	for point, point_index in result.points {
		if point != expected.points[point_index] {return {}, false}
	}
	for reference, reference_index in result.source_demand_references {
		if reference != expected.source_demand_references[reference_index] {
			return {}, false
		}
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/support-geometry",
		SCHEMA_VERSION_SUPPORT_GEOMETRY_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, schedule_hash)
	contracts.canonical_hash_append_content_hash(&hash, region_hash)
	contracts.canonical_hash_append_content_hash(
		&hash,
		support_demand_hash,
	)
	contracts.canonical_hash_append_content_hash(&hash, process_hash)
	contracts.canonical_hash_append_u8(&hash, u8(result.config.fill_rule))
	contracts.canonical_hash_append_u8(&hash, u8(result.config.join_type))
	contracts.canonical_hash_append_f64_bits(
		&hash,
		result.config.miter_limit,
	)
	contracts.canonical_hash_append_f64_bits(
		&hash,
		result.config.arc_tolerance,
	)
	contracts.canonical_hash_append_u8(&hash, u8(result.mode))
	contracts.canonical_hash_append_i64(&hash, i64(result.clearance_xy))
	contracts.canonical_hash_append_i64(&hash, i64(result.clearance_z))
	contracts.canonical_hash_append_i64(&hash, i64(result.expansion))
	contracts.canonical_hash_append_u32(&hash, result.interface_layers)
	contracts.canonical_hash_append_u64(&hash, result.regular_mask_count)
	contracts.canonical_hash_append_u64(&hash, result.interface_mask_count)
	contracts.canonical_hash_append_u64(
		&hash,
		result.unresolved_demand_count,
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
		contracts.canonical_hash_append_stable_id(&hash, mask.layer_id)
		contracts.canonical_hash_append_u32(&hash, mask.layer_index)
		contracts.canonical_hash_append_u8(&hash, u8(mask.kind))
		contracts.canonical_hash_append_u8(&hash, u8(mask.role))
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
		u64(len(result.source_demand_references)),
	)
	for reference in result.source_demand_references {
		contracts.canonical_hash_append_u32(&hash, reference)
	}
	return contracts.canonical_hash_final(&hash), true
}
