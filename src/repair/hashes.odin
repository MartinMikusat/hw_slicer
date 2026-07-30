package repair

import contracts "../contracts"
import polygon "../polygon"

SCHEMA_VERSION_CONTOUR_REPAIR_HASH :: u32(1)

contour_repair_result_hash :: proc(
	topology_hash: contracts.Content_Hash,
	result: Contour_Repair_Result,
) -> (contracts.Content_Hash, bool) {
	if result.source_path_id == contracts.INVALID_STABLE_ID ||
	   result.failure_edge_a == result.failure_edge_b ||
	   i64(result.lineage_tolerance_um) < 0 ||
	   len(result.edges) != len(result.output.points) {
		return {}, false
	}
	output_hash, output_hash_ok := polygon.polygon_set_hash(result.output)
	if !output_hash_ok {return {}, false}
	expected_source_offset: u64
	expected_edge_index := 0
	expected_path_index := 0
	multi_source_edge_count: u64
	maximum_deviation_um: u64
	for edge in result.edges {
		for expected_path_index < len(result.output.paths) &&
		    expected_edge_index >=
		    	int(result.output.paths[expected_path_index].count) {
			expected_path_index += 1
			expected_edge_index = 0
		}
		if expected_path_index >= len(result.output.paths) ||
		   edge.output_path_index != u32(expected_path_index) ||
		   edge.output_edge_index != u32(expected_edge_index) ||
		   edge.source_offset != expected_source_offset ||
		   edge.source_count == 0 ||
		   expected_source_offset > u64(len(result.sources)) ||
		   u64(edge.source_count) >
		   	u64(len(result.sources))-expected_source_offset {
			return {}, false
		}
		if edge.source_count > 1 {multi_source_edge_count += 1}
		source_end := expected_source_offset+u64(edge.source_count)
		for source in result.sources[
		    int(expected_source_offset):int(source_end)] {
			if source.path_id != result.source_path_id ||
			   source.path_index != result.source_path_index ||
			   source.maximum_deviation_um >
			   	u64(i64(result.lineage_tolerance_um)) {
				return {}, false
			}
			maximum_deviation_um = max(
				maximum_deviation_um,
				source.maximum_deviation_um,
			)
		}
		expected_source_offset = source_end
		expected_edge_index += 1
	}
	if expected_source_offset != u64(len(result.sources)) ||
	   multi_source_edge_count != result.multi_source_edge_count ||
	   maximum_deviation_um != result.maximum_deviation_um {
		return {}, false
	}
	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/contour-repair",
		SCHEMA_VERSION_CONTOUR_REPAIR_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, topology_hash)
	contracts.canonical_hash_append_stable_id(
		&hash,
		result.source_path_id,
	)
	contracts.canonical_hash_append_u32(&hash, result.source_path_index)
	contracts.canonical_hash_append_u32(&hash, result.layer_index)
	contracts.canonical_hash_append_u32(&hash, result.failure_edge_a)
	contracts.canonical_hash_append_u32(&hash, result.failure_edge_b)
	contracts.canonical_hash_append_u8(&hash, u8(result.fill_rule))
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.lineage_tolerance_um),
	)
	contracts.canonical_hash_append_content_hash(&hash, output_hash)
	contracts.canonical_hash_append_u64(&hash, result.lineage_test_count)
	contracts.canonical_hash_append_u64(
		&hash,
		result.multi_source_edge_count,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.maximum_deviation_um,
	)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.edges)))
	for edge in result.edges {
		contracts.canonical_hash_append_u32(
			&hash,
			edge.output_path_index,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			edge.output_edge_index,
		)
		contracts.canonical_hash_append_u64(&hash, edge.source_offset)
		contracts.canonical_hash_append_u32(&hash, edge.source_count)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.sources)))
	for source in result.sources {
		contracts.canonical_hash_append_stable_id(&hash, source.path_id)
		contracts.canonical_hash_append_u32(&hash, source.path_index)
		contracts.canonical_hash_append_u32(&hash, source.edge_index)
		contracts.canonical_hash_append_u32(&hash, source.segment_index)
		contracts.canonical_hash_append_u64(
			&hash,
			source.maximum_deviation_um,
		)
	}
	return contracts.canonical_hash_final(&hash), true
}
