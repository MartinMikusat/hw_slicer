package features

import contracts "../contracts"
import polygon "../polygon"
import profiles "../profiles"
import slicing "../slicing"

SCHEMA_VERSION_BRIDGE_DIRECTION_HASH :: u32(1)

bridge_direction_result_hash :: proc(
	region_hash: contracts.Content_Hash,
	bridge_evidence_hash: contracts.Content_Hash,
	process_hash: contracts.Content_Hash,
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	evidence: Bridge_Evidence_Result,
	process: profiles.Resolved_Process_Profile,
	provider: polygon.Polygon_Provider,
	result: Bridge_Direction_Result,
	limits := DEFAULT_BRIDGE_DIRECTION_LIMITS,
	allocator := context.allocator,
) -> (contracts.Content_Hash, bool) {
	calculated_region_hash, regions_ok :=
		slicing.region_result_hash({}, topology, regions)
	if !regions_ok || calculated_region_hash != region_hash ||
	   !bridge_direction_evidence_valid(regions, evidence) ||
	   !profiles.process_bridge_targets_valid(process.source) ||
	   process.source.bridge_direction != .Bounded_Candidate_Score ||
	   evidence.geometry_policy != process.source.bridge_geometry ||
	   evidence.anchor_margin != process.source.bridge_anchor_margin ||
	   evidence.minimum_area != process.source.minimum_bridge_area ||
	   result.policy != process.source.bridge_direction ||
	   result.scale != BRIDGE_DIRECTION_SCALE ||
	   len(result.layers) != len(evidence.layers) ||
	   provider.offset == nil {
		return {}, false
	}
	supports, support_error := bridge_direction_supports_build(
		topology,
		regions,
		process.source.bridge_anchor_margin,
		provider,
		evidence.config,
		limits.polygon,
		allocator,
	)
	if support_error != .None {return {}, false}
	defer {
		for &support in supports {
			polygon.polygon_set_destroy(&support, allocator)
		}
		delete(supports, allocator)
	}

	selection_cursor := 0
	candidate_cursor := 0
	for layer, layer_index in result.layers {
		layer_selection_start := selection_cursor
		layer_candidate_start := candidate_cursor
		evidence_layer := evidence.layers[layer_index]
		mask_start := int(evidence_layer.mask_offset)
		mask_end := mask_start+int(evidence_layer.mask_count)
		for mask_index in mask_start..<mask_end {
			mask := evidence.masks[mask_index]
			if mask.kind != .Eligible_Unsupported {continue}
			if selection_cursor >= len(result.selections) {
				return {}, false
			}
			selection := result.selections[selection_cursor]
			region := regions.regions[mask.region_index]
			candidate_start := candidate_cursor
			boundary, boundary_error :=
				bridge_evidence_mask_input(
					evidence,
					u32(mask_index),
					allocator,
				)
			if boundary_error != .None {return {}, false}
			best_index := candidate_cursor
			for angle_index in
			    0..<int(process.source.bridge_angle_count) {
				if candidate_cursor >= len(result.candidates) {
					polygon.polygon_set_destroy(
						&boundary,
						allocator,
					)
					return {}, false
				}
				candidate := result.candidates[candidate_cursor]
				angle := process.source.bridge_angles[angle_index]
				direction_x, direction_y, direction_ok :=
					bridge_direction_vector(angle)
				score, score_ok := bridge_direction_score_candidate(
					boundary,
					supports[layer_index],
					direction_x,
					direction_y,
				)
				expected_id := contracts.stable_id_child(
					mask.stable_id,
					.Property,
					u64(angle_index),
				)
				if !direction_ok || !score_ok ||
				   candidate.stable_id != expected_id ||
				   candidate.evidence_mask_id != mask.stable_id ||
				   candidate.evidence_mask_index != u32(mask_index) ||
				   candidate.angle_index != u8(angle_index) ||
				   candidate.angle != angle ||
				   candidate.direction_x != direction_x ||
				   candidate.direction_y != direction_y ||
				   candidate.span_projection !=
				    score.span_projection ||
				   candidate.positive_anchor_capacity !=
				    score.positive_anchor_capacity ||
				   candidate.negative_anchor_capacity !=
				    score.negative_anchor_capacity ||
				   candidate.bidirectional_anchor_capacity !=
				    score.bidirectional_anchor_capacity ||
				   candidate.total_anchor_capacity !=
				    score.total_anchor_capacity {
					polygon.polygon_set_destroy(
						&boundary,
						allocator,
					)
					return {}, false
				}
				if candidate_cursor > candidate_start &&
				   bridge_direction_candidate_better(
						candidate,
						result.candidates[best_index],
				   ) {
					best_index = candidate_cursor
				}
				candidate_cursor += 1
			}
			polygon.polygon_set_destroy(&boundary, allocator)
			expected_status := Bridge_Direction_Status.Selected
			if result.candidates[best_index].
			   bidirectional_anchor_capacity == 0 {
				expected_status = .No_Bidirectional_Anchor
			}
			if selection.evidence_mask_id != mask.stable_id ||
			   selection.evidence_mask_index != u32(mask_index) ||
			   selection.region_id != region.stable_id ||
			   selection.region_index != mask.region_index ||
			   selection.layer_index != mask.layer_index ||
			   selection.status != expected_status ||
			   selection.selected_candidate_index != u32(best_index) ||
			   selection.candidate_offset != u64(candidate_start) ||
			   selection.candidate_count !=
			    process.source.bridge_angle_count {
				return {}, false
			}
			selection_cursor += 1
		}
		if layer.selection_offset != u64(layer_selection_start) ||
		   layer.selection_count !=
		    u32(selection_cursor-layer_selection_start) ||
		   layer.candidate_offset != u64(layer_candidate_start) ||
		   layer.candidate_count !=
		    u32(candidate_cursor-layer_candidate_start) {
			return {}, false
		}
	}
	if selection_cursor != len(result.selections) ||
	   candidate_cursor != len(result.candidates) {
		return {}, false
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/bridge-directions",
		SCHEMA_VERSION_BRIDGE_DIRECTION_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, region_hash)
	contracts.canonical_hash_append_content_hash(
		&hash,
		bridge_evidence_hash,
	)
	contracts.canonical_hash_append_content_hash(&hash, process_hash)
	contracts.canonical_hash_append_u8(&hash, u8(result.policy))
	contracts.canonical_hash_append_i64(&hash, result.scale)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.layers)))
	for layer in result.layers {
		contracts.canonical_hash_append_u64(
			&hash,
			layer.selection_offset,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			layer.selection_count,
		)
		contracts.canonical_hash_append_u64(
			&hash,
			layer.candidate_offset,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			layer.candidate_count,
		)
	}
	contracts.canonical_hash_append_u64(
		&hash,
		u64(len(result.selections)),
	)
	for selection in result.selections {
		contracts.canonical_hash_append_stable_id(
			&hash,
			selection.evidence_mask_id,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			selection.evidence_mask_index,
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			selection.region_id,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			selection.region_index,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			selection.layer_index,
		)
		contracts.canonical_hash_append_u8(
			&hash,
			u8(selection.status),
		)
		contracts.canonical_hash_append_u32(
			&hash,
			selection.selected_candidate_index,
		)
		contracts.canonical_hash_append_u64(
			&hash,
			selection.candidate_offset,
		)
		contracts.canonical_hash_append_u8(
			&hash,
			selection.candidate_count,
		)
	}
	contracts.canonical_hash_append_u64(
		&hash,
		u64(len(result.candidates)),
	)
	for candidate in result.candidates {
		contracts.canonical_hash_append_stable_id(
			&hash,
			candidate.stable_id,
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			candidate.evidence_mask_id,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			candidate.evidence_mask_index,
		)
		contracts.canonical_hash_append_u8(
			&hash,
			candidate.angle_index,
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(candidate.angle),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			candidate.direction_x,
		)
		contracts.canonical_hash_append_i64(
			&hash,
			candidate.direction_y,
		)
		contracts.canonical_hash_append_i128(
			&hash,
			candidate.span_projection,
		)
		bridge_direction_hash_append_u128(
			&hash,
			candidate.positive_anchor_capacity,
		)
		bridge_direction_hash_append_u128(
			&hash,
			candidate.negative_anchor_capacity,
		)
		bridge_direction_hash_append_u128(
			&hash,
			candidate.bidirectional_anchor_capacity,
		)
		bridge_direction_hash_append_u128(
			&hash,
			candidate.total_anchor_capacity,
		)
	}
	return contracts.canonical_hash_final(&hash), true
}

bridge_direction_hash_append_u128 :: proc(
	hash: ^contracts.Canonical_Hash,
	value: u128,
) {
	contracts.canonical_hash_append_u64(hash, u64(value))
	contracts.canonical_hash_append_u64(hash, u64(value>>64))
}
