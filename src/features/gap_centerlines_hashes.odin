package features

import contracts "../contracts"

SCHEMA_VERSION_GAP_CENTERLINE_HASH :: u32(1)

gap_centerline_result_hash :: proc(
	gap_evidence_hash: contracts.Content_Hash,
	gap_sample_hash: contracts.Content_Hash,
	evidence: Gap_Evidence_Result,
	samples: Gap_Sample_Result,
	result: Gap_Centerline_Result,
	allocator := context.allocator,
) -> (contracts.Content_Hash, bool) {
	if result.minimum_samples_per_path < 2 ||
	   len(result.layers) != len(samples.layers) ||
	   len(samples.layers) != len(evidence.layers) ||
	   u64(len(samples.samples)) > u64(max(u32)) {
		return {}, false
	}
	if !gap_centerline_sample_ranges_valid(evidence, samples) {
		return {}, false
	}

	runs := make([]Gap_Centerline_Run, len(samples.samples), allocator)
	if len(samples.samples) > 0 && runs == nil {
		return {}, false
	}
	defer delete(runs, allocator)
	run_count, run_error := gap_centerline_collect_runs(samples, runs)
	if run_error != .None {return {}, false}
	runs = runs[:run_count]

	path_cursor := 0
	vertex_cursor := 0
	issue_cursor := 0
	run_cursor := 0
	for layer, layer_index in result.layers {
		layer_path_start := path_cursor
		layer_vertex_start := vertex_cursor
		layer_issue_start := issue_cursor
		for run_cursor < len(runs) {
			run := runs[run_cursor]
			first_sample_index := int(run.sample_offset)
			if first_sample_index >= len(samples.samples) {
				return {}, false
			}
			first_sample := samples.samples[first_sample_index]
			if first_sample.layer_index != u32(layer_index) {break}
			mask := evidence.masks[run.evidence_mask_index]
			expected_issue := run.issue
			if expected_issue == .Invalid &&
			   run.sample_count < result.minimum_samples_per_path {
				expected_issue = .Insufficient_Samples
			}
			if expected_issue != .Invalid {
				if issue_cursor >= len(result.issues) ||
				   !gap_centerline_issue_matches(
						result.issues[issue_cursor],
						expected_issue,
						run,
						mask,
				   ) {
					return {}, false
				}
				issue_cursor += 1
				run_cursor += 1
				continue
			}

			for line_index in 0..<int(run.line_count) {
				if path_cursor >= len(result.paths) {
					return {}, false
				}
				path := result.paths[path_cursor]
				expected_role := gap_centerline_role(
					evidence,
					mask.region_index,
				)
				expected_id := contracts.stable_id_child(
					mask.stable_id,
					.Path,
					u64(run.mask_run_index)*2+
						u64(line_index),
				)
				if path.stable_id != expected_id ||
				   path.evidence_mask_id != mask.stable_id ||
				   path.evidence_mask_index != run.evidence_mask_index ||
				   path.region_id != mask.region_id ||
				   path.region_index != mask.region_index ||
				   path.layer_index != mask.layer_index ||
				   path.role != expected_role ||
				   path.mask_run_index != run.mask_run_index ||
				   path.line_index != u8(line_index) ||
				   path.sample_offset != run.sample_offset ||
				   path.sample_count != run.sample_count ||
				   path.vertex_offset != u64(vertex_cursor) ||
				   path.vertex_count != run.sample_count {
					return {}, false
				}
				sample_end :=
					first_sample_index+int(run.sample_count)
				for sample_index in
				    first_sample_index..<sample_end {
					if vertex_cursor >= len(result.vertices) {
						return {}, false
					}
					sample := samples.samples[sample_index]
					center_index :=
						int(sample.center_offset)+line_index
					if center_index >= len(samples.centers) ||
					   !gap_centerline_vertex_matches(
							result.vertices[vertex_cursor],
							samples.centers[center_index],
							sample,
							u32(sample_index),
					   ) {
						return {}, false
					}
					vertex_cursor += 1
				}
				path_cursor += 1
			}
			run_cursor += 1
		}
		if layer.path_offset != u64(layer_path_start) ||
		   layer.path_count != u32(path_cursor-layer_path_start) ||
		   layer.vertex_offset != u64(layer_vertex_start) ||
		   layer.vertex_count != u32(vertex_cursor-layer_vertex_start) ||
		   layer.issue_offset != u64(layer_issue_start) ||
		   layer.issue_count != u32(issue_cursor-layer_issue_start) {
			return {}, false
		}
	}
	if run_cursor != len(runs) ||
	   path_cursor != len(result.paths) ||
	   vertex_cursor != len(result.vertices) ||
	   issue_cursor != len(result.issues) {
		return {}, false
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/gap-centerlines",
		SCHEMA_VERSION_GAP_CENTERLINE_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, gap_evidence_hash)
	contracts.canonical_hash_append_content_hash(&hash, gap_sample_hash)
	contracts.canonical_hash_append_u32(
		&hash,
		result.minimum_samples_per_path,
	)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.layers)))
	for layer in result.layers {
		contracts.canonical_hash_append_u64(&hash, layer.path_offset)
		contracts.canonical_hash_append_u32(&hash, layer.path_count)
		contracts.canonical_hash_append_u64(&hash, layer.vertex_offset)
		contracts.canonical_hash_append_u32(&hash, layer.vertex_count)
		contracts.canonical_hash_append_u64(&hash, layer.issue_offset)
		contracts.canonical_hash_append_u32(&hash, layer.issue_count)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.paths)))
	for path in result.paths {
		contracts.canonical_hash_append_stable_id(&hash, path.stable_id)
		contracts.canonical_hash_append_stable_id(
			&hash,
			path.evidence_mask_id,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			path.evidence_mask_index,
		)
		contracts.canonical_hash_append_stable_id(&hash, path.region_id)
		contracts.canonical_hash_append_u32(&hash, path.region_index)
		contracts.canonical_hash_append_u32(&hash, path.layer_index)
		contracts.canonical_hash_append_u8(&hash, u8(path.role))
		contracts.canonical_hash_append_u32(&hash, path.mask_run_index)
		contracts.canonical_hash_append_u8(&hash, path.line_index)
		contracts.canonical_hash_append_u64(&hash, path.sample_offset)
		contracts.canonical_hash_append_u32(&hash, path.sample_count)
		contracts.canonical_hash_append_u64(&hash, path.vertex_offset)
		contracts.canonical_hash_append_u32(&hash, path.vertex_count)
	}
	contracts.canonical_hash_append_u64(
		&hash,
		u64(len(result.vertices)),
	)
	for vertex in result.vertices {
		contracts.canonical_hash_append_stable_id(
			&hash,
			vertex.sample_id,
		)
		contracts.canonical_hash_append_u32(&hash, vertex.sample_index)
		contracts.canonical_hash_append_i64(&hash, i64(vertex.point.x))
		contracts.canonical_hash_append_i64(&hash, i64(vertex.point.y))
		contracts.canonical_hash_append_i64(
			&hash,
			vertex.exact_x_twice_um,
		)
		contracts.canonical_hash_append_i64(
			&hash,
			vertex.exact_y_twice_um,
		)
		contracts.canonical_hash_append_u8(
			&hash,
			vertex.round_error_x_2x,
		)
		contracts.canonical_hash_append_u8(
			&hash,
			vertex.round_error_y_2x,
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(vertex.line_width),
		)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.issues)))
	for issue in result.issues {
		contracts.canonical_hash_append_u8(&hash, u8(issue.kind))
		contracts.canonical_hash_append_stable_id(
			&hash,
			issue.evidence_mask_id,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			issue.evidence_mask_index,
		)
		contracts.canonical_hash_append_stable_id(&hash, issue.region_id)
		contracts.canonical_hash_append_u32(&hash, issue.region_index)
		contracts.canonical_hash_append_u32(&hash, issue.layer_index)
		contracts.canonical_hash_append_u64(&hash, issue.sample_offset)
		contracts.canonical_hash_append_u32(&hash, issue.sample_count)
	}
	return contracts.canonical_hash_final(&hash), true
}

gap_centerline_sample_ranges_valid :: proc(
	evidence: Gap_Evidence_Result,
	samples: Gap_Sample_Result,
) -> bool {
	expected_sample_offset: u64
	expected_center_offset: u64
	for layer, layer_index in samples.layers {
		if layer.sample_offset != expected_sample_offset ||
		   layer.center_offset != expected_center_offset ||
		   layer.sample_offset+u64(layer.sample_count) >
		    u64(len(samples.samples)) ||
		   layer.center_offset+u64(layer.center_count) >
		    u64(len(samples.centers)) {
			return false
		}
		sample_end :=
			int(layer.sample_offset)+int(layer.sample_count)
		center_count: u64
		for sample in samples.samples[int(layer.sample_offset):sample_end] {
			if sample.layer_index != u32(layer_index) {
				return false
			}
			center_count += u64(sample.center_count)
		}
		if center_count != u64(layer.center_count) {return false}
		expected_sample_offset += u64(layer.sample_count)
		expected_center_offset += u64(layer.center_count)
	}
	if expected_sample_offset != u64(len(samples.samples)) ||
	   expected_center_offset != u64(len(samples.centers)) {
		return false
	}

	previous_mask_index: u32
	for sample, sample_index in samples.samples {
		if u64(sample.evidence_mask_index) >=
		    u64(len(evidence.masks)) ||
		   sample.center_offset+u64(sample.center_count) >
		    u64(len(samples.centers)) {
			return false
		}
		mask := evidence.masks[sample.evidence_mask_index]
		if mask.kind != .Uncovered_Region ||
		   sample.evidence_mask_id != mask.stable_id ||
		   sample.region_id != mask.region_id ||
		   sample.region_index != mask.region_index ||
		   sample.layer_index != mask.layer_index ||
		   sample_index > 0 &&
		    sample.evidence_mask_index < previous_mask_index {
			return false
		}
		previous_mask_index = sample.evidence_mask_index
	}
	return true
}

gap_centerline_issue_matches :: proc(
	issue: Gap_Centerline_Issue,
	expected_kind: Gap_Centerline_Issue_Kind,
	run: Gap_Centerline_Run,
	mask: Gap_Evidence_Mask,
) -> bool {
	return issue.kind == expected_kind &&
		issue.evidence_mask_id == mask.stable_id &&
		issue.evidence_mask_index == run.evidence_mask_index &&
		issue.region_id == mask.region_id &&
		issue.region_index == mask.region_index &&
		issue.layer_index == mask.layer_index &&
		issue.sample_offset == run.sample_offset &&
		issue.sample_count == run.sample_count
}

gap_centerline_vertex_matches :: proc(
	vertex: Gap_Centerline_Vertex,
	center: Gap_Center_Sample,
	sample: Gap_Width_Sample,
	sample_index: u32,
) -> bool {
	point, error_x, error_y, round_ok :=
		gap_centerline_round_point(center)
	return round_ok &&
		vertex.sample_id == sample.stable_id &&
		vertex.sample_index == sample_index &&
		vertex.point == point &&
		vertex.exact_x_twice_um == center.x_twice_um &&
		vertex.exact_y_twice_um == center.y_twice_um &&
		vertex.round_error_x_2x == error_x &&
		vertex.round_error_y_2x == error_y &&
		vertex.line_width == center.line_width
}
