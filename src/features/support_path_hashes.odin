package features

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"

SCHEMA_VERSION_SUPPORT_PATH_HASH :: u32(1)

support_path_result_hash :: proc(
	support_geometry_hash: contracts.Content_Hash,
	process_hash: contracts.Content_Hash,
	support_geometry: Support_Geometry_Result,
	process: profiles.Resolved_Process_Profile,
	provider: polygon.Polygon_Provider,
	result: Support_Path_Result,
	limits := DEFAULT_SUPPORT_PATH_LIMITS,
	allocator := context.allocator,
) -> (contracts.Content_Hash, bool) {
	expected, expected_error := support_paths_generate(
		support_geometry,
		process,
		provider,
		limits,
		allocator,
	)
	if expected_error != .None {return {}, false}
	defer support_path_result_destroy(&expected, allocator)
	if result.pattern != expected.pattern ||
	   result.line_width != expected.line_width ||
	   result.regular_spacing != expected.regular_spacing ||
	   result.interface_spacing != expected.interface_spacing ||
	   result.boundary_inset != expected.boundary_inset ||
	   result.phase != expected.phase ||
	   result.base_axis != expected.base_axis ||
	   result.alternate_each_layer != expected.alternate_each_layer ||
	   result.scanline_count != expected.scanline_count ||
	   result.regular_path_count != expected.regular_path_count ||
	   result.interface_path_count != expected.interface_path_count ||
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
		"hw-slicer/support-paths",
		SCHEMA_VERSION_SUPPORT_PATH_HASH,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		support_geometry_hash,
	)
	contracts.canonical_hash_append_content_hash(&hash, process_hash)
	contracts.canonical_hash_append_u8(&hash, u8(result.pattern))
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.line_width),
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.regular_spacing),
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.interface_spacing),
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.boundary_inset),
	)
	contracts.canonical_hash_append_i64(&hash, i64(result.phase))
	contracts.canonical_hash_append_u8(&hash, u8(result.base_axis))
	contracts.canonical_hash_append_u8(
		&hash,
		u8(result.alternate_each_layer),
	)
	contracts.canonical_hash_append_u64(&hash, result.scanline_count)
	contracts.canonical_hash_append_u64(
		&hash,
		result.regular_path_count,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.interface_path_count,
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
			path.geometry_mask_id,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			path.geometry_mask_index,
		)
		contracts.canonical_hash_append_u32(&hash, path.layer_index)
		contracts.canonical_hash_append_u8(&hash, u8(path.kind))
		contracts.canonical_hash_append_u8(&hash, u8(path.role))
		contracts.canonical_hash_append_u8(&hash, u8(path.axis))
		contracts.canonical_hash_append_u64(
			&hash,
			path.mask_path_index,
		)
		contracts.canonical_hash_append_u64(
			&hash,
			path.scanline_index,
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(path.line_coordinate),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(path.line_width),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(path.spacing),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(path.point_a.x),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(path.point_a.y),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(path.point_b.x),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(path.point_b.y),
		)
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
		contracts.canonical_hash_append_i128(&hash, hit.numerator)
		contracts.canonical_hash_append_i128(&hash, hit.denominator)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(hit.rounded_coordinate),
		)
		contracts.canonical_hash_append_u64(
			&hash,
			u64(hit.error_numerator),
		)
		contracts.canonical_hash_append_u64(
			&hash,
			u64(hit.error_numerator>>64),
		)
	}
	return contracts.canonical_hash_final(&hash), true
}
