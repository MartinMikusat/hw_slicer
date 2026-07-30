package features

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"

Gap_Path_Axis :: enum u8 {
	Invalid,
	Horizontal,
	Vertical,
}

Gap_Sample_Config :: struct {
	spacing: contracts.Micrometres,
	phase:   contracts.Micrometres,
}

Gap_Sample_Limits :: struct {
	max_scanlines: u64,
	max_samples:   u64,
	max_centers:   u64,
}

DEFAULT_GAP_SAMPLE_LIMITS :: Gap_Sample_Limits{
	max_scanlines = 1_000_000_000,
	max_samples = 2_000_000_000,
	max_centers = 4_000_000_000,
}

Gap_Sample_Layer :: struct {
	sample_offset: u64,
	sample_count:  u32,
	center_offset: u64,
	center_count:  u32,
}

Gap_Width_Sample :: struct {
	stable_id:          contracts.Stable_ID,
	evidence_mask_id:   contracts.Stable_ID,
	evidence_mask_index: u32,
	region_id:          contracts.Stable_ID,
	region_index:       u32,
	layer_index:        u32,
	mask_sample_index:  u32,
	path_axis:          Gap_Path_Axis,
	scan_coordinate:    contracts.Micrometres,
	cross_minimum:      contracts.Micrometres,
	cross_maximum:      contracts.Micrometres,
	allocation:         profiles.Gap_Width_Allocation,
	center_offset:      u64,
	center_count:       u8,
	hit_offset:         u64,
}

Gap_Center_Sample :: struct {
	sample_id:      contracts.Stable_ID,
	line_index:     u8,
	x_twice_um:     i64,
	y_twice_um:     i64,
	line_width:     contracts.Micrometres,
}

Gap_Sample_Result :: struct {
	config:         Gap_Sample_Config,
	minimum_width:  contracts.Micrometres,
	maximum_width:  contracts.Micrometres,
	layers:         []Gap_Sample_Layer,
	samples:        []Gap_Width_Sample,
	centers:        []Gap_Center_Sample,
	boundary_hits:  []Infill_Boundary_Hit,
	scanline_count: u64,
}

Gap_Sample_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Scanline_Limit,
	Sample_Limit,
	Center_Limit,
	Odd_Intersection_Count,
	Allocation_Failed,
	Arithmetic,
}

gap_samples_build :: proc(
	evidence: Gap_Evidence_Result,
	process: profiles.Resolved_Process_Profile,
	config: Gap_Sample_Config,
	limits := DEFAULT_GAP_SAMPLE_LIMITS,
	allocator := context.allocator,
) -> (Gap_Sample_Result, Gap_Sample_Error) {
	if !gap_sample_config_valid(config) ||
	   evidence.config.minimum_line_width !=
	   	process.thin_wall_minimum_width ||
	   evidence.config.maximum_line_width !=
	   	process.thin_wall_maximum_width ||
	   process.source.gap_allocation != .One_Then_Two_Lines ||
	   process.source.thin_wall_remainder != .Preserve_Unprinted {
		return {}, .Invalid_Config
	}
	if u64(len(evidence.masks)) > u64(max(u32)) {
		return {}, .Arithmetic
	}
	maximum_points := 0
	for mask in evidence.masks {
		if mask.kind == .Uncovered_Region {
			maximum_points = max(maximum_points, int(mask.point_count))
		}
	}
	hits := make([]Infill_Rational_Hit, maximum_points, allocator)
	if maximum_points > 0 && hits == nil {
		return {}, .Allocation_Failed
	}
	defer delete(hits, allocator)

	result := Gap_Sample_Result{
		config = config,
		minimum_width = process.thin_wall_minimum_width,
		maximum_width = process.thin_wall_maximum_width,
	}
	result.layers = make(
		[]Gap_Sample_Layer,
		len(evidence.layers),
		allocator,
	)
	if len(evidence.layers) > 0 && result.layers == nil {
		gap_sample_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	sample_count: u64
	center_count: u64
	for mask, mask_index in evidence.masks {
		if mask.kind != .Uncovered_Region {continue}
		boundary, boundary_error := gap_evidence_mask_input(
			evidence,
			u32(mask_index),
			allocator,
		)
		if boundary_error != .None {
			gap_sample_result_destroy(&result, allocator)
			return {}, boundary_error
		}
		path_axis := gap_sample_path_axis(boundary)
		written_samples, written_centers, scanlines, scan_error :=
			gap_sample_scan_mask(
				boundary,
				path_axis,
				config,
				process,
				hits,
				nil,
				nil,
				nil,
				mask,
				u32(mask_index),
				0,
				0,
				limits,
			)
		polygon.polygon_set_destroy(&boundary, allocator)
		if scan_error != .None {
			gap_sample_result_destroy(&result, allocator)
			return {}, scan_error
		}
		if sample_count > limits.max_samples ||
		   written_samples > limits.max_samples-sample_count {
			gap_sample_result_destroy(&result, allocator)
			return {}, .Sample_Limit
		}
		if center_count > limits.max_centers ||
		   written_centers > limits.max_centers-center_count {
			gap_sample_result_destroy(&result, allocator)
			return {}, .Center_Limit
		}
		if result.scanline_count > limits.max_scanlines ||
		   scanlines > limits.max_scanlines-result.scanline_count {
			gap_sample_result_destroy(&result, allocator)
			return {}, .Scanline_Limit
		}
		sample_count += written_samples
		center_count += written_centers
		result.scanline_count += scanlines
	}
	if sample_count > u64(max(int)) ||
	   center_count > u64(max(int)) ||
	   sample_count > u64(max(int))/2 {
		gap_sample_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	result.samples = make(
		[]Gap_Width_Sample,
		int(sample_count),
		allocator,
	)
	result.centers = make(
		[]Gap_Center_Sample,
		int(center_count),
		allocator,
	)
	result.boundary_hits = make(
		[]Infill_Boundary_Hit,
		int(sample_count*2),
		allocator,
	)
	if sample_count > 0 &&
	   (result.samples == nil || result.boundary_hits == nil) ||
	   center_count > 0 && result.centers == nil {
		gap_sample_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	sample_write: u64
	center_write: u64
	for layer, layer_index in evidence.layers {
		layer_sample_start := sample_write
		layer_center_start := center_write
		mask_start := int(layer.mask_offset)
		mask_end := mask_start+int(layer.mask_count)
		for mask_index in mask_start..<mask_end {
			mask := evidence.masks[mask_index]
			if mask.kind != .Uncovered_Region {continue}
			boundary, boundary_error := gap_evidence_mask_input(
				evidence,
				u32(mask_index),
				allocator,
			)
			if boundary_error != .None {
				gap_sample_result_destroy(&result, allocator)
				return {}, boundary_error
			}
			written_samples, written_centers, _, scan_error :=
				gap_sample_scan_mask(
					boundary,
					gap_sample_path_axis(boundary),
					config,
					process,
					hits,
					result.samples,
					result.centers,
					result.boundary_hits,
					mask,
					u32(mask_index),
					sample_write,
					center_write,
					limits,
				)
			polygon.polygon_set_destroy(&boundary, allocator)
			if scan_error != .None {
				gap_sample_result_destroy(&result, allocator)
				return {}, scan_error
			}
			sample_write += written_samples
			center_write += written_centers
		}
		layer_sample_count := sample_write-layer_sample_start
		layer_center_count := center_write-layer_center_start
		if layer_sample_count > u64(max(u32)) ||
		   layer_center_count > u64(max(u32)) {
			gap_sample_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		result.layers[layer_index] = {
			sample_offset = layer_sample_start,
			sample_count = u32(layer_sample_count),
			center_offset = layer_center_start,
			center_count = u32(layer_center_count),
		}
	}
	if sample_write != sample_count || center_write != center_count {
		gap_sample_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

gap_sample_scan_mask :: proc(
	boundary: polygon.Polygon_Set,
	path_axis: Gap_Path_Axis,
	config: Gap_Sample_Config,
	process: profiles.Resolved_Process_Profile,
	hits: []Infill_Rational_Hit,
	samples: []Gap_Width_Sample,
	centers: []Gap_Center_Sample,
	boundary_hits: []Infill_Boundary_Hit,
	mask: Gap_Evidence_Mask,
	mask_index: u32,
	sample_offset, center_offset: u64,
	limits: Gap_Sample_Limits,
) -> (
	sample_count: u64,
	center_count: u64,
	scanline_count: u64,
	error: Gap_Sample_Error,
) {
	if len(boundary.points) == 0 || path_axis == .Invalid {return}
	scan_axis := Infill_Axis.Vertical
	if path_axis == .Vertical {scan_axis = .Horizontal}
	minimum, maximum := infill_boundary_axis_bounds(boundary, scan_axis)
	line, line_ok := infill_first_scanline(
		minimum,
		config.phase,
		config.spacing,
	)
	if !line_ok {error = .Arithmetic; return}
	mask_sample_index: u32
	for i128(i64(line)) < i128(i64(maximum)) {
		if scanline_count >= limits.max_scanlines {
			error = .Scanline_Limit
			return
		}
		scanline_count += 1
		hit_count, hit_error := infill_collect_hits(
			boundary,
			scan_axis,
			line,
			hits,
		)
		if hit_error == .Odd_Intersection_Count {
			error = .Odd_Intersection_Count
			return
		}
		if hit_error != .None {error = .Arithmetic; return}
		if hit_count&1 != 0 {
			error = .Odd_Intersection_Count
			return
		}
		hit_index := 0
		for hit_index < hit_count {
			first := hits[hit_index]
			second := hits[hit_index+1]
			width_128 := i128(second.rounded_coordinate)-
				i128(first.rounded_coordinate)
			if width_128 <= 0 {
				hit_index += 2
				continue
			}
			if width_128 > i128(max(i64)) ||
			   sample_count >= limits.max_samples {
				error = .Sample_Limit
				return
			}
			allocation, allocation_ok := profiles.gap_width_allocate(
				process,
				contracts.Micrometres(width_128),
			)
			if !allocation_ok {
				error = .Invalid_Config
				return
			}
			if center_count+u64(allocation.line_count) >
			   	limits.max_centers {
				error = .Center_Limit
				return
			}
			sample_id := contracts.stable_id_child(
				mask.stable_id,
				.Feature,
				u64(mask_sample_index),
			)
			if samples != nil {
				write_index := sample_offset+sample_count
				center_write := center_offset+center_count
				if write_index >= u64(len(samples)) ||
				   write_index*2+1 >= u64(len(boundary_hits)) ||
				   center_write+u64(allocation.line_count) >
				   	u64(len(centers)) {
					error = .Arithmetic
					return
				}
				samples[write_index] = {
					stable_id = sample_id,
					evidence_mask_id = mask.stable_id,
					evidence_mask_index = mask_index,
					region_id = mask.region_id,
					region_index = mask.region_index,
					layer_index = mask.layer_index,
					mask_sample_index = mask_sample_index,
					path_axis = path_axis,
					scan_coordinate = line,
					cross_minimum = first.rounded_coordinate,
					cross_maximum = second.rounded_coordinate,
					allocation = allocation,
					center_offset = center_write,
					center_count = allocation.line_count,
					hit_offset = write_index*2,
				}
				boundary_hits[write_index*2] =
					infill_boundary_hit(first)
				boundary_hits[write_index*2+1] =
					infill_boundary_hit(second)
				for line_allocation, line_index in
				    allocation.lines[:allocation.line_count] {
					fixed_twice := i64(line)*2
					variable_twice :=
						i64(first.rounded_coordinate)*2+
						line_allocation.center_twice_um
					x_twice := fixed_twice
					y_twice := variable_twice
					if path_axis == .Vertical {
						x_twice, y_twice =
							variable_twice, fixed_twice
					}
					centers[center_write+u64(line_index)] = {
						sample_id = sample_id,
						line_index = u8(line_index),
						x_twice_um = x_twice,
						y_twice_um = y_twice,
						line_width = line_allocation.width,
					}
				}
			}
			sample_count += 1
			center_count += u64(allocation.line_count)
			mask_sample_index += 1
			hit_index += 2
		}
		next := i128(line)+i128(config.spacing)
		if next > i128(geometry.MAX_PLANAR_COORDINATE_UM) {
			break
		}
		line = contracts.Micrometres(next)
	}
	return
}

gap_evidence_mask_input :: proc(
	evidence: Gap_Evidence_Result,
	mask_index: u32,
	allocator := context.allocator,
) -> (polygon.Polygon_Set, Gap_Sample_Error) {
	if u64(mask_index) >= u64(len(evidence.masks)) {
		return {}, .Invalid_Input
	}
	mask := evidence.masks[mask_index]
	if mask.kind != .Uncovered_Region ||
	   mask.path_offset+u64(mask.path_count) >
	   	u64(len(evidence.paths)) ||
	   mask.point_offset+u64(mask.point_count) >
	   	u64(len(evidence.points)) {
		return {}, .Invalid_Input
	}
	result: polygon.Polygon_Set
	result.paths = make(
		[]polygon.Polygon_Path,
		int(mask.path_count),
		allocator,
	)
	result.points = make(
		[]polygon.Polygon_Point,
		int(mask.point_count),
		allocator,
	)
	if result.paths == nil || result.points == nil {
		polygon.polygon_set_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	point_write := 0
	path_start := int(mask.path_offset)
	path_end := path_start+int(mask.path_count)
	for path, local_path_index in evidence.paths[path_start:path_end] {
		if path.point_offset+u64(path.point_count) >
		   	u64(len(evidence.points)) {
			polygon.polygon_set_destroy(&result, allocator)
			return {}, .Invalid_Input
		}
		result.paths[local_path_index] = {
			offset = u64(point_write),
			count = u64(path.point_count),
		}
		source_start := int(path.point_offset)
		source_end := source_start+int(path.point_count)
		copy(
			result.points[
				point_write:point_write+int(path.point_count)
			],
			evidence.points[source_start:source_end],
		)
		point_write += int(path.point_count)
	}
	if point_write != len(result.points) {
		polygon.polygon_set_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

gap_sample_path_axis :: proc(
	boundary: polygon.Polygon_Set,
) -> Gap_Path_Axis {
	if len(boundary.points) == 0 {return .Invalid}
	minimum_x, maximum_x := boundary.points[0].x, boundary.points[0].x
	minimum_y, maximum_y := boundary.points[0].y, boundary.points[0].y
	for point in boundary.points[1:] {
		minimum_x = min(minimum_x, point.x)
		maximum_x = max(maximum_x, point.x)
		minimum_y = min(minimum_y, point.y)
		maximum_y = max(maximum_y, point.y)
	}
	x_span := i128(maximum_x)-i128(minimum_x)
	y_span := i128(maximum_y)-i128(minimum_y)
	if x_span >= y_span {return .Horizontal}
	return .Vertical
}

gap_sample_config_valid :: proc(config: Gap_Sample_Config) -> bool {
	return i64(config.spacing) > 0 &&
		i64(config.spacing) <= geometry.MAX_PLANAR_COORDINATE_UM &&
		i64(config.phase) >= 0 &&
		i64(config.phase) < i64(config.spacing)
}

gap_sample_result_destroy :: proc(
	result: ^Gap_Sample_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.samples, allocator)
	delete(result.centers, allocator)
	delete(result.boundary_hits, allocator)
	result^ = {}
}
