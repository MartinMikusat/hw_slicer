package features

import contracts "../contracts"
import profiles "../profiles"

SCHEMA_VERSION_UNIFIED_PATH_SOURCE_HASH :: u32(1)

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

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/unified-path-sources",
		SCHEMA_VERSION_UNIFIED_PATH_SOURCE_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, perimeter_hash)
	contracts.canonical_hash_append_content_hash(&hash, bridge_hash)
	contracts.canonical_hash_append_content_hash(&hash, gap_hash)
	contracts.canonical_hash_append_content_hash(&hash, solid_hash)
	contracts.canonical_hash_append_content_hash(&hash, infill_hash)
	contracts.canonical_hash_append_content_hash(&hash, support_hash)
	contracts.canonical_hash_append_content_hash(&hash, process_hash)
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
