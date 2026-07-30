package features

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"

Support_Path_Layer :: struct {
	path_offset: u64,
	path_count:  u32,
	hit_offset:  u64,
	hit_count:   u32,
}

Support_Path :: struct {
	stable_id:           contracts.Stable_ID,
	geometry_mask_id:    contracts.Stable_ID,
	geometry_mask_index: u32,
	layer_index:         u32,
	kind:                Support_Geometry_Kind,
	role:                profiles.Printable_Role,
	axis:                Infill_Axis,
	mask_path_index:     u64,
	scanline_index:      u64,
	line_coordinate:     contracts.Micrometres,
	line_width:          contracts.Micrometres,
	spacing:             contracts.Micrometres,
	point_a:             polygon.Polygon_Point,
	point_b:             polygon.Polygon_Point,
	hit_offset:          u64,
}

Support_Path_Result :: struct {
	pattern:              profiles.Support_Pattern,
	line_width:           contracts.Micrometres,
	regular_spacing:      contracts.Micrometres,
	interface_spacing:    contracts.Micrometres,
	boundary_inset:       contracts.Micrometres,
	phase:                contracts.Micrometres,
	base_axis:            Infill_Axis,
	alternate_each_layer: bool,
	layers:               []Support_Path_Layer,
	paths:                []Support_Path,
	hits:                 []Infill_Boundary_Hit,
	scanline_count:       u64,
	regular_path_count:   u64,
	interface_path_count: u64,
}

Support_Path_Limits :: struct {
	max_scanlines: u64,
	max_paths:     u64,
	polygon:       polygon.Polygon_Limits,
}

DEFAULT_SUPPORT_PATH_LIMITS :: Support_Path_Limits{
	max_scanlines = 1_000_000_000,
	max_paths = 1_000_000_000,
	polygon = polygon.DEFAULT_POLYGON_LIMITS,
}

Support_Path_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Scanline_Limit,
	Path_Limit,
	Provider,
	Odd_Intersection_Count,
	Allocation_Failed,
	Arithmetic,
}

support_paths_generate :: proc(
	support_geometry: Support_Geometry_Result,
	process: profiles.Resolved_Process_Profile,
	provider: polygon.Polygon_Provider,
	limits := DEFAULT_SUPPORT_PATH_LIMITS,
	allocator := context.allocator,
) -> (Support_Path_Result, Support_Path_Error) {
	line_width := process.source.nominal_line_width
	regular_spacing, regular_spacing_ok := support_path_regular_spacing(
		line_width,
		process.source.support_density,
	)
	boundary_inset, boundary_inset_ok :=
		support_path_boundary_inset(line_width)
	if !profiles.process_support_targets_valid(process.source) ||
	   process.source.support_pattern != .Rectilinear ||
	   !regular_spacing_ok || !boundary_inset_ok ||
	   i64(process.source.support_interface_spacing) >
		geometry.MAX_PLANAR_COORDINATE_UM ||
	   provider.offset == nil {
		return {}, .Invalid_Config
	}
	if !support_path_geometry_valid(support_geometry, process) {
		return {}, .Invalid_Input
	}
	interface_spacing := process.source.support_interface_spacing
	phase := contracts.Micrometres(0)
	base_axis := Infill_Axis.Vertical
	alternate_each_layer := true

	boundaries := make(
		[]polygon.Polygon_Set,
		len(support_geometry.masks),
		allocator,
	)
	if len(support_geometry.masks) > 0 && boundaries == nil {
		return {}, .Allocation_Failed
	}
	defer {
		for &boundary in boundaries {
			polygon.polygon_set_destroy(&boundary, allocator)
		}
		delete(boundaries, allocator)
	}
	maximum_boundary_points := 0
	for mask, mask_index in support_geometry.masks {
		input, input_error := support_geometry_mask_input(
			support_geometry,
			u32(mask_index),
			allocator,
		)
		if input_error != .None {
			return {}, support_path_geometry_error(input_error)
		}
		provider_error: polygon.Polygon_Error
		boundaries[mask_index], provider_error = provider.offset(
			input,
			-contracts.Micrometres(i64(boundary_inset)),
			support_geometry.config.join_type,
			support_geometry.config.miter_limit,
			support_geometry.config.arc_tolerance,
			limits.polygon,
			allocator,
		)
		polygon.polygon_set_destroy(&input, allocator)
		if provider_error != .None {
			return {}, .Provider
		}
		maximum_boundary_points = max(
			maximum_boundary_points,
			len(boundaries[mask_index].points),
		)
	}
	scratch_hits := make(
		[]Infill_Rational_Hit,
		maximum_boundary_points,
		allocator,
	)
	if maximum_boundary_points > 0 && scratch_hits == nil {
		return {}, .Allocation_Failed
	}
	defer delete(scratch_hits, allocator)

	path_count: u64
	scanline_count: u64
	regular_path_count: u64
	interface_path_count: u64
	for mask, mask_index in support_geometry.masks {
		axis := support_path_layer_axis(
			base_axis,
			alternate_each_layer,
			mask.layer_index,
		)
		spacing := regular_spacing
		if mask.kind == .Interface {spacing = interface_spacing}
		written_paths, written_scanlines, scan_error :=
			support_path_scan_boundary(
				boundaries[mask_index],
				axis,
				spacing,
				phase,
				line_width,
				scratch_hits,
				nil,
				nil,
				mask,
				u32(mask_index),
				0,
				limits,
			)
		if scan_error != .None {return {}, scan_error}
		if path_count > limits.max_paths ||
		   written_paths > limits.max_paths-path_count {
			return {}, .Path_Limit
		}
		if scanline_count > limits.max_scanlines ||
		   written_scanlines > limits.max_scanlines-scanline_count {
			return {}, .Scanline_Limit
		}
		path_count += written_paths
		scanline_count += written_scanlines
		if mask.kind == .Regular {
			regular_path_count += written_paths
		} else {
			interface_path_count += written_paths
		}
	}
	if path_count > u64(max(int)) ||
	   path_count > u64(max(int))/2 {
		return {}, .Arithmetic
	}

	result := Support_Path_Result{
		pattern = process.source.support_pattern,
		line_width = line_width,
		regular_spacing = regular_spacing,
		interface_spacing = interface_spacing,
		boundary_inset = boundary_inset,
		phase = phase,
		base_axis = base_axis,
		alternate_each_layer = alternate_each_layer,
		scanline_count = scanline_count,
		regular_path_count = regular_path_count,
		interface_path_count = interface_path_count,
	}
	result.layers = make(
		[]Support_Path_Layer,
		len(support_geometry.layers),
		allocator,
	)
	result.paths = make([]Support_Path, int(path_count), allocator)
	result.hits = make(
		[]Infill_Boundary_Hit,
		int(path_count*2),
		allocator,
	)
	if len(result.layers) > 0 && result.layers == nil ||
	   path_count > 0 &&
		(result.paths == nil || result.hits == nil) {
		support_path_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	path_write: u64
	mask_cursor := 0
	for geometry_layer, layer_index in support_geometry.layers {
		layer_path_start := path_write
		mask_end :=
			int(geometry_layer.mask_offset)+
			int(geometry_layer.mask_count)
		for mask_cursor < mask_end {
			mask := support_geometry.masks[mask_cursor]
			axis := support_path_layer_axis(
				base_axis,
				alternate_each_layer,
				mask.layer_index,
			)
			spacing := regular_spacing
			if mask.kind == .Interface {
				spacing = interface_spacing
			}
			written_paths, _, scan_error :=
				support_path_scan_boundary(
					boundaries[mask_cursor],
					axis,
					spacing,
					phase,
					line_width,
					scratch_hits,
					result.paths,
					result.hits,
					mask,
					u32(mask_cursor),
					path_write,
					limits,
				)
			if scan_error != .None {
				support_path_result_destroy(&result, allocator)
				return {}, scan_error
			}
			path_write += written_paths
			mask_cursor += 1
		}
		layer_path_count := path_write-layer_path_start
		if layer_path_count > u64(max(u32)) ||
		   layer_path_count > u64(max(u32))/2 {
			support_path_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		result.layers[layer_index] = {
			path_offset = layer_path_start,
			path_count = u32(layer_path_count),
			hit_offset = layer_path_start*2,
			hit_count = u32(layer_path_count*2),
		}
	}
	if path_write != path_count ||
	   mask_cursor != len(support_geometry.masks) {
		support_path_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

support_path_scan_boundary :: proc(
	boundary: polygon.Polygon_Set,
	axis: Infill_Axis,
	spacing, phase, line_width: contracts.Micrometres,
	scratch_hits: []Infill_Rational_Hit,
	paths: []Support_Path,
	output_hits: []Infill_Boundary_Hit,
	mask: Support_Geometry_Mask,
	mask_index: u32,
	path_offset: u64,
	limits: Support_Path_Limits,
) -> (
	path_count: u64,
	scanline_count: u64,
	error: Support_Path_Error,
) {
	if len(boundary.points) == 0 {return}
	minimum, maximum := infill_boundary_axis_bounds(boundary, axis)
	line, line_ok := infill_first_scanline(minimum, phase, spacing)
	if !line_ok {error = .Arithmetic; return}
	mask_path_index: u64
	for i128(i64(line)) < i128(i64(maximum)) {
		if scanline_count >= limits.max_scanlines {
			error = .Scanline_Limit
			return
		}
		scanline_index := scanline_count
		scanline_count += 1
		hit_count, hit_error := infill_collect_hits(
			boundary,
			axis,
			line,
			scratch_hits,
		)
		if hit_error != .None {
			error = support_path_infill_error(hit_error)
			return
		}
		if hit_count&1 != 0 {
			error = .Odd_Intersection_Count
			return
		}
		for hit_index := 0; hit_index < hit_count; hit_index += 2 {
			first := scratch_hits[hit_index]
			second := scratch_hits[hit_index+1]
			if first.rounded_coordinate ==
			   second.rounded_coordinate {
				continue
			}
			if path_count >= limits.max_paths {
				error = .Path_Limit
				return
			}
			if paths != nil {
				write_index := path_offset+path_count
				if write_index >= u64(len(paths)) ||
				   write_index*2+1 >= u64(len(output_hits)) {
					error = .Arithmetic
					return
				}
				point_a, point_b := infill_segment_points(
					axis,
					line,
					first.rounded_coordinate,
					second.rounded_coordinate,
				)
				paths[write_index] = {
					stable_id = contracts.stable_id_child(
						mask.stable_id,
						.Path,
						mask_path_index,
					),
					geometry_mask_id = mask.stable_id,
					geometry_mask_index = mask_index,
					layer_index = mask.layer_index,
					kind = mask.kind,
					role = mask.role,
					axis = axis,
					mask_path_index = mask_path_index,
					scanline_index = scanline_index,
					line_coordinate = line,
					line_width = line_width,
					spacing = spacing,
					point_a = point_a,
					point_b = point_b,
					hit_offset = write_index*2,
				}
				output_hits[write_index*2] =
					infill_boundary_hit(first)
				output_hits[write_index*2+1] =
					infill_boundary_hit(second)
			}
			path_count += 1
			mask_path_index += 1
		}
		next := i128(i64(line))+i128(i64(spacing))
		if next > i128(geometry.MAX_PLANAR_COORDINATE_UM) {
			break
		}
		line = contracts.Micrometres(i64(next))
	}
	return
}

support_path_regular_spacing :: proc(
	line_width: contracts.Micrometres,
	density: profiles.Ratio_Ppm,
) -> (contracts.Micrometres, bool) {
	if i64(line_width) <= 0 ||
	   i64(line_width) > geometry.MAX_PLANAR_COORDINATE_UM ||
	   u32(density) == 0 ||
	   u32(density) > profiles.RATIO_SCALE {
		return 0, false
	}
	numerator :=
		i128(i64(line_width))*i128(profiles.RATIO_SCALE)
	denominator := i128(u32(density))
	spacing := (numerator+denominator-1)/denominator
	if spacing <= 0 ||
	   spacing > i128(geometry.MAX_PLANAR_COORDINATE_UM) {
		return 0, false
	}
	return contracts.Micrometres(i64(spacing)), true
}

support_path_boundary_inset :: proc(
	line_width: contracts.Micrometres,
) -> (contracts.Micrometres, bool) {
	if i64(line_width) <= 0 ||
	   i64(line_width) > geometry.MAX_PLANAR_COORDINATE_UM {
		return 0, false
	}
	return contracts.Micrometres((i64(line_width)+1)/2), true
}

support_path_layer_axis :: proc(
	base_axis: Infill_Axis,
	alternate_each_layer: bool,
	layer_index: u32,
) -> Infill_Axis {
	if !alternate_each_layer || layer_index&1 == 0 {
		return base_axis
	}
	if base_axis == .Vertical {return .Horizontal}
	return .Vertical
}

support_path_geometry_valid :: proc(
	support_geometry: Support_Geometry_Result,
	process: profiles.Resolved_Process_Profile,
) -> bool {
	if !support_demand_config_valid(support_geometry.config) ||
	   support_geometry.mode != process.source.support_mode ||
	   support_geometry.clearance_xy !=
		process.source.support_clearance_xy ||
	   support_geometry.clearance_z !=
		process.source.support_clearance_z ||
	   support_geometry.expansion != process.source.support_expansion ||
	   support_geometry.interface_layers !=
		process.source.support_interface_layers {
		return false
	}
	expected_mask_offset: u64
	expected_path_offset: u64
	expected_point_offset: u64
	expected_source_offset: u64
	regular_mask_count: u64
	interface_mask_count: u64
	for layer, layer_index in support_geometry.layers {
		if layer.mask_offset != expected_mask_offset ||
		   layer.path_offset != expected_path_offset ||
		   layer.source_reference_offset != expected_source_offset ||
		   layer.mask_offset+u64(layer.mask_count) >
			u64(len(support_geometry.masks)) ||
		   layer.path_offset+u64(layer.path_count) >
			u64(len(support_geometry.paths)) ||
		   layer.source_reference_offset+
			u64(layer.source_reference_count) >
			u64(len(support_geometry.source_demand_references)) {
			return false
		}
		mask_start := int(layer.mask_offset)
		mask_end := mask_start+int(layer.mask_count)
		previous_kind := Support_Geometry_Kind.Invalid
		for mask in support_geometry.masks[mask_start:mask_end] {
			expected_role := profiles.Printable_Role.Support
			if mask.kind == .Interface {
				expected_role = .Support_Interface
				interface_mask_count += 1
			} else if mask.kind == .Regular {
				regular_mask_count += 1
			} else {
				return false
			}
			ordinal, ordinal_ok :=
				feature_support_geometry_ordinal(mask.kind)
			if !ordinal_ok ||
			   mask.stable_id == contracts.INVALID_STABLE_ID ||
			   mask.layer_id == contracts.INVALID_STABLE_ID ||
			   mask.stable_id != contracts.stable_id_child(
				mask.layer_id,
				.Feature,
				ordinal,
			   ) ||
			   mask.layer_index != u32(layer_index) ||
			   mask.role != expected_role ||
			   mask.kind <= previous_kind ||
			   mask.path_offset != expected_path_offset ||
			   mask.point_offset != expected_point_offset ||
			   mask.source_reference_offset != expected_source_offset ||
			   mask.path_offset+u64(mask.path_count) >
				u64(len(support_geometry.paths)) ||
			   mask.point_offset+u64(mask.point_count) >
				u64(len(support_geometry.points)) ||
			   mask.source_reference_offset+
				u64(mask.source_reference_count) >
				u64(len(
					support_geometry.source_demand_references,
				)) {
				return false
			}
			path_start := int(mask.path_offset)
			path_end := path_start+int(mask.path_count)
			mask_point_count: u64
			for path, local_path_index in
			    support_geometry.paths[path_start:path_end] {
				if path.mask_id != mask.stable_id ||
				   path.mask_path_index != u32(local_path_index) ||
				   path.stable_id != contracts.stable_id_child(
					mask.stable_id,
					.Path,
					u64(local_path_index),
				   ) ||
				   path.point_offset !=
					expected_point_offset+mask_point_count ||
				   path.point_count < 3 ||
				   path.point_offset+u64(path.point_count) >
					u64(len(support_geometry.points)) {
					return false
				}
				point_start := int(path.point_offset)
				point_end := point_start+int(path.point_count)
				points :=
					support_geometry.points[point_start:point_end]
				area_2 := polygon.polygon_path_area_2(points)
				winding := geometry.Predicate_Sign.Positive
				if area_2 < 0 {winding = .Negative}
				if area_2 == 0 ||
				   path.signed_area_2 != area_2 ||
				   path.winding != winding {
					return false
				}
				for point in points {
					if geometry.point_2_validate({
						point.x,
						point.y,
					}) != .None {
						return false
					}
				}
				mask_point_count += u64(path.point_count)
			}
			if mask_point_count != u64(mask.point_count) {
				return false
			}
			reference_start := int(mask.source_reference_offset)
			reference_end :=
				reference_start+int(mask.source_reference_count)
			references := support_geometry.source_demand_references[
				reference_start:reference_end
			]
			previous_reference: u32
			for reference, reference_index in references {
				if reference_index > 0 &&
				   reference <= previous_reference {
					return false
				}
				previous_reference = reference
			}
			expected_path_offset += u64(mask.path_count)
			expected_point_offset += u64(mask.point_count)
			expected_source_offset +=
				u64(mask.source_reference_count)
			previous_kind = mask.kind
		}
		if expected_path_offset !=
		   layer.path_offset+u64(layer.path_count) ||
		   expected_source_offset !=
		   layer.source_reference_offset+
			u64(layer.source_reference_count) {
			return false
		}
		expected_mask_offset += u64(layer.mask_count)
	}
	return expected_mask_offset == u64(len(support_geometry.masks)) &&
		expected_path_offset == u64(len(support_geometry.paths)) &&
		expected_point_offset == u64(len(support_geometry.points)) &&
		expected_source_offset ==
			u64(len(support_geometry.source_demand_references)) &&
		regular_mask_count == support_geometry.regular_mask_count &&
		interface_mask_count == support_geometry.interface_mask_count
}

support_path_infill_error :: proc(
	error: Infill_Error,
) -> Support_Path_Error {
	#partial switch error {
	case .Odd_Intersection_Count: return .Odd_Intersection_Count
	case .Allocation_Failed:      return .Allocation_Failed
	case .Arithmetic:             return .Arithmetic
	}
	return .Invalid_Input
}

support_path_geometry_error :: proc(
	error: Support_Geometry_Error,
) -> Support_Path_Error {
	#partial switch error {
	case .Allocation_Failed: return .Allocation_Failed
	case .Arithmetic:        return .Arithmetic
	}
	return .Invalid_Input
}

support_path_result_destroy :: proc(
	result: ^Support_Path_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.paths, allocator)
	delete(result.hits, allocator)
	result^ = {}
}
