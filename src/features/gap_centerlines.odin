package features

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"

Gap_Centerline_Issue_Kind :: enum u8 {
	Invalid,
	Unprinted_Below_Minimum,
	Unprinted_Transition,
	Above_Two_Line_Maximum,
	Ambiguous_Branch,
	Insufficient_Samples,
}

Gap_Centerline_Layer :: struct {
	path_offset:   u64,
	path_count:    u32,
	vertex_offset: u64,
	vertex_count:  u32,
	issue_offset:  u64,
	issue_count:   u32,
}

Gap_Centerline_Path :: struct {
	stable_id:          contracts.Stable_ID,
	evidence_mask_id:   contracts.Stable_ID,
	evidence_mask_index: u32,
	region_id:          contracts.Stable_ID,
	region_index:       u32,
	layer_index:        u32,
	role:               profiles.Printable_Role,
	mask_run_index:     u32,
	line_index:         u8,
	sample_offset:      u64,
	sample_count:       u32,
	vertex_offset:      u64,
	vertex_count:       u32,
}

Gap_Centerline_Vertex :: struct {
	sample_id:       contracts.Stable_ID,
	sample_index:    u32,
	point:           polygon.Polygon_Point,
	exact_x_twice_um: i64,
	exact_y_twice_um: i64,
	round_error_x_2x: u8,
	round_error_y_2x: u8,
	line_width:      contracts.Micrometres,
}

Gap_Centerline_Issue :: struct {
	kind:               Gap_Centerline_Issue_Kind,
	evidence_mask_id:   contracts.Stable_ID,
	evidence_mask_index: u32,
	region_id:          contracts.Stable_ID,
	region_index:       u32,
	layer_index:        u32,
	sample_offset:      u64,
	sample_count:       u32,
}

Gap_Centerline_Result :: struct {
	minimum_samples_per_path: u32,
	layers:                   []Gap_Centerline_Layer,
	paths:                    []Gap_Centerline_Path,
	vertices:                 []Gap_Centerline_Vertex,
	issues:                   []Gap_Centerline_Issue,
}

Gap_Centerline_Limits :: struct {
	max_paths:    u64,
	max_vertices: u64,
	max_issues:   u64,
}

DEFAULT_GAP_CENTERLINE_LIMITS :: Gap_Centerline_Limits{
	max_paths = 1_000_000_000,
	max_vertices = 4_000_000_000,
	max_issues = 1_000_000_000,
}

Gap_Centerline_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Path_Limit,
	Vertex_Limit,
	Issue_Limit,
	Allocation_Failed,
	Arithmetic,
}

Gap_Centerline_Run :: struct {
	evidence_mask_index: u32,
	mask_run_index:      u32,
	sample_offset:       u64,
	sample_count:        u32,
	line_count:          u8,
	issue:               Gap_Centerline_Issue_Kind,
}

gap_centerlines_build :: proc(
	evidence: Gap_Evidence_Result,
	samples: Gap_Sample_Result,
	minimum_samples_per_path := u32(2),
	limits := DEFAULT_GAP_CENTERLINE_LIMITS,
	allocator := context.allocator,
) -> (Gap_Centerline_Result, Gap_Centerline_Error) {
	if minimum_samples_per_path < 2 {
		return {}, .Invalid_Config
	}
	if len(samples.layers) != len(evidence.layers) ||
	   u64(len(samples.samples)) > u64(max(u32)) {
		return {}, .Invalid_Input
	}
	runs := make([]Gap_Centerline_Run, len(samples.samples), allocator)
	if len(samples.samples) > 0 && runs == nil {
		return {}, .Allocation_Failed
	}
	defer delete(runs, allocator)
	run_count, run_error := gap_centerline_collect_runs(samples, runs)
	if run_error != .None {return {}, run_error}
	runs = runs[:run_count]

	path_count: u64
	vertex_count: u64
	issue_count: u64
	for run in runs {
		if run.issue != .Invalid ||
		   run.sample_count < minimum_samples_per_path {
			issue_count += 1
			if issue_count > limits.max_issues {
				return {}, .Issue_Limit
			}
			continue
		}
		path_count += u64(run.line_count)
		added_vertices := u64(run.sample_count)*u64(run.line_count)
		if path_count > limits.max_paths {
			return {}, .Path_Limit
		}
		if vertex_count > limits.max_vertices ||
		   added_vertices > limits.max_vertices-vertex_count {
			return {}, .Vertex_Limit
		}
		vertex_count += added_vertices
	}
	if path_count > u64(max(int)) ||
	   vertex_count > u64(max(int)) ||
	   issue_count > u64(max(int)) {
		return {}, .Arithmetic
	}

	result := Gap_Centerline_Result{
		minimum_samples_per_path = minimum_samples_per_path,
	}
	result.layers = make(
		[]Gap_Centerline_Layer,
		len(samples.layers),
		allocator,
	)
	result.paths = make(
		[]Gap_Centerline_Path,
		int(path_count),
		allocator,
	)
	result.vertices = make(
		[]Gap_Centerline_Vertex,
		int(vertex_count),
		allocator,
	)
	result.issues = make(
		[]Gap_Centerline_Issue,
		int(issue_count),
		allocator,
	)
	if len(result.layers) > 0 && result.layers == nil ||
	   path_count > 0 && result.paths == nil ||
	   vertex_count > 0 && result.vertices == nil ||
	   issue_count > 0 && result.issues == nil {
		gap_centerline_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	path_write := 0
	vertex_write := 0
	issue_write := 0
	run_cursor := 0
	for _, layer_index in samples.layers {
		layer_path_start := path_write
		layer_vertex_start := vertex_write
		layer_issue_start := issue_write
		for run_cursor < len(runs) {
			run := runs[run_cursor]
			first_sample := samples.samples[run.sample_offset]
			if first_sample.layer_index != u32(layer_index) {break}
			mask := evidence.masks[run.evidence_mask_index]
			if run.issue != .Invalid ||
			   run.sample_count < minimum_samples_per_path {
				issue_kind := run.issue
				if issue_kind == .Invalid {
					issue_kind = .Insufficient_Samples
				}
				result.issues[issue_write] = {
					kind = issue_kind,
					evidence_mask_id = mask.stable_id,
					evidence_mask_index =
						run.evidence_mask_index,
					region_id = mask.region_id,
					region_index = mask.region_index,
					layer_index = mask.layer_index,
					sample_offset = run.sample_offset,
					sample_count = run.sample_count,
				}
				issue_write += 1
				run_cursor += 1
				continue
			}
			role := gap_centerline_role(evidence, mask.region_index)
			for line_index in 0..<int(run.line_count) {
				path_vertex_start := vertex_write
				sample_end :=
					int(run.sample_offset)+int(run.sample_count)
				for sample_index in
				    int(run.sample_offset)..<sample_end {
					sample := samples.samples[sample_index]
					center_index :=
						int(sample.center_offset)+line_index
					if center_index >= len(samples.centers) {
						gap_centerline_result_destroy(
							&result,
							allocator,
						)
						return {}, .Invalid_Input
					}
					center := samples.centers[center_index]
					point, error_x, error_y, round_ok :=
						gap_centerline_round_point(center)
					if !round_ok {
						gap_centerline_result_destroy(
							&result,
							allocator,
						)
						return {}, .Arithmetic
					}
					result.vertices[vertex_write] = {
						sample_id = sample.stable_id,
						sample_index = u32(sample_index),
						point = point,
						exact_x_twice_um = center.x_twice_um,
						exact_y_twice_um = center.y_twice_um,
						round_error_x_2x = error_x,
						round_error_y_2x = error_y,
						line_width = center.line_width,
					}
					vertex_write += 1
				}
				path_id := contracts.stable_id_child(
					mask.stable_id,
					.Path,
					u64(run.mask_run_index)*2+
						u64(line_index),
				)
				result.paths[path_write] = {
					stable_id = path_id,
					evidence_mask_id = mask.stable_id,
					evidence_mask_index =
						run.evidence_mask_index,
					region_id = mask.region_id,
					region_index = mask.region_index,
					layer_index = mask.layer_index,
					role = role,
					mask_run_index = run.mask_run_index,
					line_index = u8(line_index),
					sample_offset = run.sample_offset,
					sample_count = run.sample_count,
					vertex_offset = u64(path_vertex_start),
					vertex_count =
						u32(vertex_write-path_vertex_start),
				}
				path_write += 1
			}
			run_cursor += 1
		}
		layer_path_count := path_write-layer_path_start
		layer_vertex_count := vertex_write-layer_vertex_start
		layer_issue_count := issue_write-layer_issue_start
		if layer_path_count > int(max(u32)) ||
		   layer_vertex_count > int(max(u32)) ||
		   layer_issue_count > int(max(u32)) {
			gap_centerline_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		result.layers[layer_index] = {
			path_offset = u64(layer_path_start),
			path_count = u32(layer_path_count),
			vertex_offset = u64(layer_vertex_start),
			vertex_count = u32(layer_vertex_count),
			issue_offset = u64(layer_issue_start),
			issue_count = u32(layer_issue_count),
		}
	}
	if run_cursor != len(runs) ||
	   path_write != len(result.paths) ||
	   vertex_write != len(result.vertices) ||
	   issue_write != len(result.issues) {
		gap_centerline_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

gap_centerline_collect_runs :: proc(
	samples: Gap_Sample_Result,
	runs: []Gap_Centerline_Run,
) -> (int, Gap_Centerline_Error) {
	run_write := 0
	sample_cursor := 0
	for sample_cursor < len(samples.samples) {
		mask_index := samples.samples[sample_cursor].evidence_mask_index
		mask_start := sample_cursor
		for sample_cursor < len(samples.samples) &&
		    samples.samples[sample_cursor].evidence_mask_index == mask_index {
			sample_cursor += 1
		}
		mask_end := sample_cursor
		ambiguous := false
		for index in mask_start+1..<mask_end {
			if samples.samples[index].scan_coordinate ==
			   samples.samples[index-1].scan_coordinate {
				ambiguous = true
				break
			}
		}
		if ambiguous {
			runs[run_write] = {
				evidence_mask_index = mask_index,
				mask_run_index = 0,
				sample_offset = u64(mask_start),
				sample_count = u32(mask_end-mask_start),
				issue = .Ambiguous_Branch,
			}
			run_write += 1
			continue
		}

		run_start := mask_start
		mask_run_index: u32
		for run_start < mask_end {
			first := samples.samples[run_start]
			line_count := first.center_count
			issue := gap_centerline_allocation_issue(
				first.allocation.kind,
			)
			run_end := run_start+1
			for run_end < mask_end {
				previous := samples.samples[run_end-1]
				next := samples.samples[run_end]
				next_issue := gap_centerline_allocation_issue(
					next.allocation.kind,
				)
				expected_coordinate := i128(previous.scan_coordinate)+
					i128(samples.config.spacing)
				if next.center_count != line_count ||
				   next_issue != issue ||
				   i128(next.scan_coordinate) != expected_coordinate {
					break
				}
				run_end += 1
			}
			if run_write >= len(runs) {
				return 0, .Arithmetic
			}
			runs[run_write] = {
				evidence_mask_index = mask_index,
				mask_run_index = mask_run_index,
				sample_offset = u64(run_start),
				sample_count = u32(run_end-run_start),
				line_count = line_count,
				issue = issue,
			}
			run_write += 1
			mask_run_index += 1
			run_start = run_end
		}
	}
	return run_write, .None
}

gap_centerline_allocation_issue :: proc(
	kind: profiles.Gap_Width_Kind,
) -> Gap_Centerline_Issue_Kind {
	switch kind {
	case .One_Line, .Two_Lines:
		return .Invalid
	case .Unprinted_Below_Minimum:
		return .Unprinted_Below_Minimum
	case .Unprinted_Transition:
		return .Unprinted_Transition
	case .Above_Two_Line_Maximum:
		return .Above_Two_Line_Maximum
	case .Invalid:
		return .Ambiguous_Branch
	}
	return .Ambiguous_Branch
}

gap_centerline_role :: proc(
	evidence: Gap_Evidence_Result,
	region_index: u32,
) -> profiles.Printable_Role {
	for mask in evidence.masks {
		if mask.region_index < region_index {continue}
		if mask.region_index > region_index {break}
		if mask.kind == .Shell_Coverage {return .Gap}
	}
	return .Thin_Wall
}

gap_centerline_round_point :: proc(
	center: Gap_Center_Sample,
) -> (
	point: polygon.Polygon_Point,
	error_x, error_y: u8,
	ok: bool,
) {
	x, x_error, x_ok := gap_centerline_round_twice(center.x_twice_um)
	y, y_error, y_ok := gap_centerline_round_twice(center.y_twice_um)
	if !x_ok || !y_ok {return}
	point = {x, y}
	error_x = x_error
	error_y = y_error
	ok = true
	return
}

gap_centerline_round_twice :: proc(
	value: i64,
) -> (contracts.Micrometres, u8, bool) {
	rounded: i128
	if value >= 0 {
		rounded = (i128(value)+1)/2
	} else {
		rounded = (i128(value)-1)/2
	}
	if rounded < -i128(geometry.MAX_PLANAR_COORDINATE_UM) ||
	   rounded > i128(geometry.MAX_PLANAR_COORDINATE_UM) {
		return 0, 0, false
	}
	error := i128(value)-rounded*2
	if error < 0 {error = -error}
	return contracts.Micrometres(rounded), u8(error), true
}

gap_centerline_result_destroy :: proc(
	result: ^Gap_Centerline_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.paths, allocator)
	delete(result.vertices, allocator)
	delete(result.issues, allocator)
	result^ = {}
}
