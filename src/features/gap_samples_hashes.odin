package features

import contracts "../contracts"
import profiles "../profiles"

SCHEMA_VERSION_GAP_SAMPLE_HASH :: u32(1)

gap_sample_result_hash :: proc(
	gap_evidence_hash: contracts.Content_Hash,
	process_hash: contracts.Content_Hash,
	evidence: Gap_Evidence_Result,
	process: profiles.Resolved_Process_Profile,
	result: Gap_Sample_Result,
) -> (contracts.Content_Hash, bool) {
	if !gap_sample_config_valid(result.config) ||
	   result.minimum_width != process.thin_wall_minimum_width ||
	   result.maximum_width != process.thin_wall_maximum_width ||
	   evidence.config.minimum_line_width != result.minimum_width ||
	   evidence.config.maximum_line_width != result.maximum_width ||
	   len(result.layers) != len(evidence.layers) ||
	   len(result.boundary_hits) != len(result.samples)*2 {
		return {}, false
	}

	expected_sample_offset: u64
	expected_center_offset: u64
	for layer, layer_index in result.layers {
		if layer.sample_offset != expected_sample_offset ||
		   layer.center_offset != expected_center_offset ||
		   layer.sample_offset+u64(layer.sample_count) >
		   	u64(len(result.samples)) ||
		   layer.center_offset+u64(layer.center_count) >
		   	u64(len(result.centers)) {
			return {}, false
		}
		center_count: u64
		sample_start := int(layer.sample_offset)
		sample_end := sample_start+int(layer.sample_count)
		for sample in result.samples[sample_start:sample_end] {
			if sample.layer_index != u32(layer_index) {
				return {}, false
			}
			center_count += u64(sample.center_count)
		}
		if center_count != u64(layer.center_count) {return {}, false}
		expected_sample_offset += u64(layer.sample_count)
		expected_center_offset += u64(layer.center_count)
	}
	if expected_sample_offset != u64(len(result.samples)) ||
	   expected_center_offset != u64(len(result.centers)) {
		return {}, false
	}

	expected_center_offset = 0
	previous_mask_index: u32
	expected_mask_sample_index: u32
	observed_scanlines: u64
	previous_scan_coordinate: contracts.Micrometres
	for sample, sample_index in result.samples {
		if u64(sample.evidence_mask_index) >=
		   	u64(len(evidence.masks)) {
			return {}, false
		}
		mask := evidence.masks[sample.evidence_mask_index]
		if mask.kind != .Uncovered_Region ||
		   sample.evidence_mask_id != mask.stable_id ||
		   sample.region_id != mask.region_id ||
		   sample.region_index != mask.region_index ||
		   sample.layer_index != mask.layer_index ||
		   sample.path_axis == .Invalid ||
		   sample.cross_maximum <= sample.cross_minimum ||
		   sample.allocation.measured_width !=
		   	sample.cross_maximum-sample.cross_minimum ||
		   !profiles.gap_width_allocation_valid(
		   	sample.allocation,
		   	process,
		   ) ||
		   sample.center_offset != expected_center_offset ||
		   sample.center_count != sample.allocation.line_count ||
		   sample.hit_offset != u64(sample_index)*2 ||
		   sample.stable_id != contracts.stable_id_child(
		   	mask.stable_id,
		   	.Feature,
		   	u64(sample.mask_sample_index),
		   ) {
			return {}, false
		}
		if sample_index == 0 ||
		   sample.evidence_mask_index != previous_mask_index {
			expected_mask_sample_index = 0
		}
		if sample.evidence_mask_index < previous_mask_index ||
		   sample.mask_sample_index != expected_mask_sample_index {
			return {}, false
		}
		if sample_index == 0 ||
		   sample.evidence_mask_index != previous_mask_index ||
		   sample.scan_coordinate != previous_scan_coordinate {
			observed_scanlines += 1
		}
		hit_a := result.boundary_hits[sample.hit_offset]
		hit_b := result.boundary_hits[sample.hit_offset+1]
		if hit_a.denominator <= 0 || hit_b.denominator <= 0 ||
		   hit_a.rounded_coordinate != sample.cross_minimum ||
		   hit_b.rounded_coordinate != sample.cross_maximum {
			return {}, false
		}
		center_start := int(sample.center_offset)
		center_end := center_start+int(sample.center_count)
		for center, line_index in result.centers[center_start:center_end] {
			allocation := sample.allocation.lines[line_index]
			fixed_twice := i64(sample.scan_coordinate)*2
			variable_twice := i64(sample.cross_minimum)*2+
				allocation.center_twice_um
			expected_x := fixed_twice
			expected_y := variable_twice
			if sample.path_axis == .Vertical {
				expected_x, expected_y = variable_twice, fixed_twice
			}
			if center.sample_id != sample.stable_id ||
			   center.line_index != u8(line_index) ||
			   center.x_twice_um != expected_x ||
			   center.y_twice_um != expected_y ||
			   center.line_width != allocation.width {
				return {}, false
			}
		}
		expected_center_offset += u64(sample.center_count)
		expected_mask_sample_index += 1
		previous_mask_index = sample.evidence_mask_index
		previous_scan_coordinate = sample.scan_coordinate
	}
	if expected_center_offset != u64(len(result.centers)) ||
	   result.scanline_count < observed_scanlines {
		return {}, false
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/gap-samples",
		SCHEMA_VERSION_GAP_SAMPLE_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, gap_evidence_hash)
	contracts.canonical_hash_append_content_hash(&hash, process_hash)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.config.spacing),
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.config.phase),
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.minimum_width),
	)
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.maximum_width),
	)
	contracts.canonical_hash_append_u64(&hash, result.scanline_count)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.layers)))
	for layer in result.layers {
		contracts.canonical_hash_append_u64(&hash, layer.sample_offset)
		contracts.canonical_hash_append_u32(&hash, layer.sample_count)
		contracts.canonical_hash_append_u64(&hash, layer.center_offset)
		contracts.canonical_hash_append_u32(&hash, layer.center_count)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.samples)))
	for sample in result.samples {
		contracts.canonical_hash_append_stable_id(&hash, sample.stable_id)
		contracts.canonical_hash_append_stable_id(
			&hash,
			sample.evidence_mask_id,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			sample.evidence_mask_index,
		)
		contracts.canonical_hash_append_stable_id(&hash, sample.region_id)
		contracts.canonical_hash_append_u32(&hash, sample.region_index)
		contracts.canonical_hash_append_u32(&hash, sample.layer_index)
		contracts.canonical_hash_append_u32(
			&hash,
			sample.mask_sample_index,
		)
		contracts.canonical_hash_append_u8(&hash, u8(sample.path_axis))
		contracts.canonical_hash_append_i64(
			&hash,
			i64(sample.scan_coordinate),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(sample.cross_minimum),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(sample.cross_maximum),
		)
		append_gap_width_allocation(&hash, sample.allocation)
		contracts.canonical_hash_append_u64(&hash, sample.center_offset)
		contracts.canonical_hash_append_u8(&hash, sample.center_count)
		contracts.canonical_hash_append_u64(&hash, sample.hit_offset)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.centers)))
	for center in result.centers {
		contracts.canonical_hash_append_stable_id(&hash, center.sample_id)
		contracts.canonical_hash_append_u8(&hash, center.line_index)
		contracts.canonical_hash_append_i64(&hash, center.x_twice_um)
		contracts.canonical_hash_append_i64(&hash, center.y_twice_um)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(center.line_width),
		)
	}
	contracts.canonical_hash_append_u64(
		&hash,
		u64(len(result.boundary_hits)),
	)
	for hit in result.boundary_hits {
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

append_gap_width_allocation :: proc(
	hash: ^contracts.Canonical_Hash,
	allocation: profiles.Gap_Width_Allocation,
) {
	contracts.canonical_hash_append_u8(hash, u8(allocation.kind))
	contracts.canonical_hash_append_i64(
		hash,
		i64(allocation.measured_width),
	)
	contracts.canonical_hash_append_u8(hash, allocation.line_count)
	for line in allocation.lines {
		contracts.canonical_hash_append_i64(hash, i64(line.width))
		contracts.canonical_hash_append_i64(hash, line.center_twice_um)
	}
	contracts.canonical_hash_append_i64(
		hash,
		i64(allocation.unprinted_width),
	)
}
