package features

import contracts "../contracts"
import geometry "../geometry"
import profiles "../profiles"

SCHEMA_VERSION_UNIFIED_PATH_SOURCE_HASH :: u32(1)

Unified_Path_Source_Hash_Dependencies :: struct {
	perimeter_hash: contracts.Content_Hash,
	bridge_hash:    contracts.Content_Hash,
	gap_hash:       contracts.Content_Hash,
	solid_hash:     contracts.Content_Hash,
	infill_hash:    contracts.Content_Hash,
	support_hash:   contracts.Content_Hash,
	process_hash:   contracts.Content_Hash,
}

unified_path_source_result_hash :: proc(
	perimeter_hash, bridge_hash, gap_hash: contracts.Content_Hash,
	solid_hash, infill_hash, support_hash: contracts.Content_Hash,
	process_hash: contracts.Content_Hash,
	layer_ids: []contracts.Stable_ID,
	perimeters: Perimeter_Result,
	bridges: Bridge_Path_Result,
	gaps: Gap_Centerline_Result,
	solids: Solid_Path_Result,
	infill: Infill_Result,
	supports: Support_Path_Result,
	process: profiles.Resolved_Process_Profile,
	result: Unified_Path_Source_Result,
	limits := DEFAULT_UNIFIED_PATH_SOURCE_LIMITS,
	allocator := context.allocator,
) -> (contracts.Content_Hash, bool) {
	expected, expected_error := unified_path_sources_build(
		layer_ids,
		perimeters,
		bridges,
		gaps,
		solids,
		infill,
		supports,
		process,
		result.inner_perimeters_first,
		limits,
		allocator,
	)
	if expected_error != .None {return {}, false}
	defer unified_path_source_result_destroy(&expected, allocator)
	if result.nominal_line_width != expected.nominal_line_width ||
	   len(result.layers) != len(expected.layers) ||
	   len(result.sources) != len(expected.sources) ||
	   len(result.points) != len(expected.points) ||
	   len(result.line_widths) != len(expected.line_widths) {
		return {}, false
	}
	for layer, layer_index in result.layers {
		if layer != expected.layers[layer_index] {
			return {}, false
		}
	}
	for source, source_index in result.sources {
		expected_source := expected.sources[source_index]
		if source.stable_id != expected_source.stable_id ||
		   source.layer_id != expected_source.layer_id ||
		   source.layer_index != expected_source.layer_index ||
		   source.role != expected_source.role ||
		   source.source_kind != expected_source.source_kind ||
		   source.source_index != expected_source.source_index ||
		   source.source_order != expected_source.source_order ||
		   source.closed != expected_source.closed ||
		   len(source.points) != len(expected_source.points) ||
		   len(source.line_widths) !=
			len(expected_source.line_widths) {
			return {}, false
		}
		for point, point_index in source.points {
			if point != expected_source.points[point_index] ||
			   source.line_widths[point_index] !=
				expected_source.line_widths[point_index] {
				return {}, false
			}
		}
	}
	for point, point_index in result.points {
		if point != expected.points[point_index] ||
		   result.line_widths[point_index] !=
			expected.line_widths[point_index] {
			return {}, false
		}
	}
	return unified_path_source_result_content_hash(
		{
			perimeter_hash = perimeter_hash,
			bridge_hash = bridge_hash,
			gap_hash = gap_hash,
			solid_hash = solid_hash,
			infill_hash = infill_hash,
			support_hash = support_hash,
			process_hash = process_hash,
		},
		result,
	)
}

unified_path_source_result_content_hash :: proc(
	dependencies: Unified_Path_Source_Hash_Dependencies,
	result: Unified_Path_Source_Result,
) -> (contracts.Content_Hash, bool) {
	if !unified_path_source_result_structurally_valid(result) {
		return {}, false
	}
	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/unified-path-sources",
		SCHEMA_VERSION_UNIFIED_PATH_SOURCE_HASH,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		dependencies.perimeter_hash,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		dependencies.bridge_hash,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		dependencies.gap_hash,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		dependencies.solid_hash,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		dependencies.infill_hash,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		dependencies.support_hash,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		dependencies.process_hash,
	)
	contracts.canonical_hash_append_u8(
		&hash,
		u8(result.inner_perimeters_first),
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.nominal_line_width),
	)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.layers)))
	for layer in result.layers {
		contracts.canonical_hash_append_u64(&hash, layer.source_offset)
		contracts.canonical_hash_append_u32(&hash, layer.source_count)
		contracts.canonical_hash_append_u64(&hash, layer.point_offset)
		contracts.canonical_hash_append_u32(&hash, layer.point_count)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.sources)))
	point_offset: u64
	for source in result.sources {
		contracts.canonical_hash_append_stable_id(
			&hash,
			source.stable_id,
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			source.layer_id,
		)
		contracts.canonical_hash_append_u32(&hash, source.layer_index)
		contracts.canonical_hash_append_u8(&hash, u8(source.role))
		contracts.canonical_hash_append_u8(
			&hash,
			u8(source.source_kind),
		)
		contracts.canonical_hash_append_u32(&hash, source.source_index)
		contracts.canonical_hash_append_u64(&hash, source.source_order)
		contracts.canonical_hash_append_u8(&hash, u8(source.closed))
		contracts.canonical_hash_append_u64(&hash, point_offset)
		contracts.canonical_hash_append_u32(
			&hash,
			u32(len(source.points)),
		)
		point_offset += u64(len(source.points))
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.points)))
	for point, point_index in result.points {
		contracts.canonical_hash_append_i64(&hash, i64(point.x))
		contracts.canonical_hash_append_i64(&hash, i64(point.y))
		contracts.canonical_hash_append_i64(
			&hash,
			i64(result.line_widths[point_index]),
		)
	}
	return contracts.canonical_hash_final(&hash), true
}

unified_path_source_result_structurally_valid :: proc(
	result: Unified_Path_Source_Result,
) -> bool {
	if i64(result.nominal_line_width) <= 0 ||
	   i64(result.nominal_line_width) >
		geometry.MAX_PLANAR_COORDINATE_UM ||
	   len(result.points) != len(result.line_widths) ||
	   u64(len(result.layers)) > u64(max(u32)) {
		return false
	}
	expected_source_offset: u64
	expected_point_offset: u64
	for layer, layer_index in result.layers {
		if layer.source_offset != expected_source_offset ||
		   layer.point_offset != expected_point_offset ||
		   layer.source_offset >
			max(u64)-u64(layer.source_count) ||
		   layer.point_offset >
			max(u64)-u64(layer.point_count) ||
		   layer.source_offset+u64(layer.source_count) >
			u64(len(result.sources)) ||
		   layer.point_offset+u64(layer.point_count) >
			u64(len(result.points)) {
			return false
		}
		source_start := int(layer.source_offset)
		source_end := source_start+int(layer.source_count)
		point_cursor := int(layer.point_offset)
		point_end := point_cursor+int(layer.point_count)
		previous_kind := Unified_Path_Source_Kind.Invalid
		source_order: u64
		layer_id := contracts.INVALID_STABLE_ID
		for source in result.sources[source_start:source_end] {
			_, role_ok := profiles.printable_role_priority(source.role)
			if !role_ok ||
			   !unified_path_source_kind_valid(
				source.source_kind,
				source.role,
			   ) ||
			   source.stable_id == contracts.INVALID_STABLE_ID ||
			   source.layer_id == contracts.INVALID_STABLE_ID ||
			   source.layer_index != u32(layer_index) ||
			   source.source_kind < previous_kind ||
			   source.closed && len(source.points) < 3 ||
			   !source.closed && len(source.points) < 2 ||
			   len(source.points) != len(source.line_widths) ||
			   u64(len(source.points)) > u64(max(u32)) ||
			   point_cursor > point_end ||
			   len(source.points) > point_end-point_cursor {
				return false
			}
			if layer_id == contracts.INVALID_STABLE_ID {
				layer_id = source.layer_id
			} else if source.layer_id != layer_id {
				return false
			}
			if source.source_kind != previous_kind {
				previous_kind = source.source_kind
				source_order = 0
			}
			if source.source_order != source_order {return false}
			source_order += 1
			previous := source.points[len(source.points)-1]
			for point, point_index in source.points {
				if point != result.points[point_cursor+point_index] ||
				   source.line_widths[point_index] !=
					result.line_widths[point_cursor+point_index] ||
				   geometry.point_2_validate({point.x, point.y}) != .None ||
				   i64(source.line_widths[point_index]) <= 0 ||
				   i64(source.line_widths[point_index]) >
					geometry.MAX_PLANAR_COORDINATE_UM ||
				   point == previous {
					return false
				}
				previous = point
			}
			point_cursor += len(source.points)
		}
		if point_cursor != point_end {return false}
		expected_source_offset += u64(layer.source_count)
		expected_point_offset += u64(layer.point_count)
	}
	return expected_source_offset == u64(len(result.sources)) &&
		expected_point_offset == u64(len(result.points))
}
