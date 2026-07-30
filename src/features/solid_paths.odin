package features

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"

Solid_Path_Layer :: struct {
	path_offset: u64,
	path_count:  u32,
	hit_offset:  u64,
	hit_count:   u32,
}

Solid_Path :: struct {
	stable_id:          contracts.Stable_ID,
	path_set_id:        contracts.Stable_ID,
	overlap_mask_id:    contracts.Stable_ID,
	overlap_mask_index: u32,
	layer_index:        u32,
	role:               profiles.Printable_Role,
	angle:              profiles.Angle_Millidegrees,
	direction_x:        i64,
	direction_y:        i64,
	mask_path_index:    u64,
	scanline_index:     u64,
	line_coordinate_scaled: i128,
	line_width:         contracts.Micrometres,
	point_a:            polygon.Polygon_Point,
	point_b:            polygon.Polygon_Point,
	hit_offset:         u64,
}

Solid_Path_Result :: struct {
	spacing:          contracts.Micrometres,
	line_width:       contracts.Micrometres,
	boundary_inset:   contracts.Micrometres,
	base_angle:       profiles.Angle_Millidegrees,
	angle_step:       profiles.Angle_Millidegrees,
	direction_scale:  i64,
	layers:           []Solid_Path_Layer,
	paths:            []Solid_Path,
	hits:             []Bridge_Path_Hit,
	scanline_count:   u64,
	skin_mask_count:  u64,
	collapsed_count:  u64,
}

Solid_Path_Limits :: struct {
	max_scanlines: u64,
	max_paths:     u64,
	polygon:       polygon.Polygon_Limits,
}

DEFAULT_SOLID_PATH_LIMITS :: Solid_Path_Limits{
	max_scanlines = 1_000_000_000,
	max_paths = 1_000_000_000,
	polygon = polygon.DEFAULT_POLYGON_LIMITS,
}

Solid_Path_Error :: enum u8 {
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

solid_paths_generate :: proc(
	overlap: Role_Overlap_Result,
	process: profiles.Resolved_Process_Profile,
	provider: polygon.Polygon_Provider,
	limits := DEFAULT_SOLID_PATH_LIMITS,
	allocator := context.allocator,
) -> (Solid_Path_Result, Solid_Path_Error) {
	line_width := process.source.nominal_line_width
	spacing := process.source.solid_infill_spacing
	boundary_inset, inset_ok :=
		support_path_boundary_inset(line_width)
	if process.source.role_overlap != .Subtract_Higher_Priority ||
	   overlap.policy != process.source.role_overlap ||
	   i64(line_width) <= 0 ||
	   i64(spacing) <= 0 ||
	   i64(spacing) > geometry.MAX_PLANAR_COORDINATE_UM ||
	   !inset_ok ||
	   !profiles.angle_valid(process.source.solid_infill_base_angle) ||
	   !profiles.angle_valid(process.source.solid_infill_angle_step) ||
	   provider.offset == nil {
		return {}, .Invalid_Config
	}
	if !solid_path_overlap_valid(overlap) {
		return {}, .Invalid_Input
	}

	boundaries := make(
		[]polygon.Polygon_Set,
		len(overlap.masks),
		allocator,
	)
	if len(overlap.masks) > 0 && boundaries == nil {
		return {}, .Allocation_Failed
	}
	defer {
		for &boundary in boundaries {
			polygon.polygon_set_destroy(&boundary, allocator)
		}
		delete(boundaries, allocator)
	}
	maximum_boundary_points := 0
	skin_mask_count: u64
	collapsed_count: u64
	for mask, mask_index in overlap.masks {
		if !solid_path_role_is_skin(mask.role) {continue}
		skin_mask_count += 1
		if mask.path_count == 0 {
			collapsed_count += 1
			continue
		}
		input, input_error := role_overlap_mask_input(
			overlap,
			u32(mask_index),
			allocator,
		)
		if input_error != .None {
			return {}, solid_path_overlap_error(input_error)
		}
		provider_error: polygon.Polygon_Error
		boundaries[mask_index], provider_error = provider.offset(
			input,
			-contracts.Micrometres(i64(boundary_inset)),
			.Miter,
			2,
			0,
			limits.polygon,
			allocator,
		)
		polygon.polygon_set_destroy(&input, allocator)
		if provider_error != .None {return {}, .Provider}
		if len(boundaries[mask_index].paths) == 0 {
			collapsed_count += 1
		}
		maximum_boundary_points = max(
			maximum_boundary_points,
			len(boundaries[mask_index].points),
		)
	}
	scratch_hits := make(
		[]Bridge_Path_Rational_Hit,
		maximum_boundary_points,
		allocator,
	)
	if maximum_boundary_points > 0 && scratch_hits == nil {
		return {}, .Allocation_Failed
	}
	defer delete(scratch_hits, allocator)

	path_count: u64
	scanline_count: u64
	for mask, mask_index in overlap.masks {
		if !solid_path_role_is_skin(mask.role) ||
		   len(boundaries[mask_index].paths) == 0 {
			continue
		}
		angle := solid_path_layer_angle(
			process.source.solid_infill_base_angle,
			process.source.solid_infill_angle_step,
			mask.layer_index,
		)
		direction_x, direction_y, direction_ok :=
			bridge_direction_vector(angle)
		if !direction_ok {return {}, .Invalid_Config}
		written_paths, written_scanlines, scan_error :=
			solid_path_scan_boundary(
				boundaries[mask_index],
				angle,
				direction_x,
				direction_y,
				spacing,
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
	}
	if path_count > u64(max(int)) ||
	   path_count > u64(max(int))/2 {
		return {}, .Arithmetic
	}

	result := Solid_Path_Result{
		spacing = spacing,
		line_width = line_width,
		boundary_inset = boundary_inset,
		base_angle = process.source.solid_infill_base_angle,
		angle_step = process.source.solid_infill_angle_step,
		direction_scale = BRIDGE_DIRECTION_SCALE,
		scanline_count = scanline_count,
		skin_mask_count = skin_mask_count,
		collapsed_count = collapsed_count,
	}
	result.layers = make(
		[]Solid_Path_Layer,
		len(overlap.layers),
		allocator,
	)
	result.paths = make([]Solid_Path, int(path_count), allocator)
	result.hits = make([]Bridge_Path_Hit, int(path_count*2), allocator)
	if len(result.layers) > 0 && result.layers == nil ||
	   path_count > 0 && (result.paths == nil || result.hits == nil) {
		solid_path_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	path_write: u64
	mask_cursor := 0
	for overlap_layer, layer_index in overlap.layers {
		layer_path_start := path_write
		mask_end :=
			int(overlap_layer.mask_offset)+int(overlap_layer.mask_count)
		for mask_cursor < mask_end {
			mask := overlap.masks[mask_cursor]
			if solid_path_role_is_skin(mask.role) &&
			   len(boundaries[mask_cursor].paths) > 0 {
				angle := solid_path_layer_angle(
					process.source.solid_infill_base_angle,
					process.source.solid_infill_angle_step,
					mask.layer_index,
				)
				direction_x, direction_y, direction_ok :=
					bridge_direction_vector(angle)
				if !direction_ok {
					solid_path_result_destroy(&result, allocator)
					return {}, .Invalid_Config
				}
				written_paths, _, scan_error :=
					solid_path_scan_boundary(
						boundaries[mask_cursor],
						angle,
						direction_x,
						direction_y,
						spacing,
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
					solid_path_result_destroy(&result, allocator)
					return {}, scan_error
				}
				path_write += written_paths
			}
			mask_cursor += 1
		}
		layer_path_count := path_write-layer_path_start
		if layer_path_count > u64(max(u32)) ||
		   layer_path_count > u64(max(u32))/2 {
			solid_path_result_destroy(&result, allocator)
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
	   mask_cursor != len(overlap.masks) {
		solid_path_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

solid_path_scan_boundary :: proc(
	boundary: polygon.Polygon_Set,
	angle: profiles.Angle_Millidegrees,
	direction_x, direction_y: i64,
	spacing, line_width: contracts.Micrometres,
	scratch_hits: []Bridge_Path_Rational_Hit,
	paths: []Solid_Path,
	output_hits: []Bridge_Path_Hit,
	mask: Role_Overlap_Mask,
	mask_index: u32,
	path_offset: u64,
	limits: Solid_Path_Limits,
) -> (
	path_count: u64,
	scanline_count: u64,
	error: Solid_Path_Error,
) {
	if len(boundary.points) == 0 {return}
	normal_x := -direction_y
	normal_y := direction_x
	minimum, maximum := bridge_path_projection_bounds(
		boundary,
		normal_x,
		normal_y,
	)
	step := i128(i64(spacing))*i128(BRIDGE_DIRECTION_SCALE)
	if step <= 0 {error = .Invalid_Config; return}
	line, line_ok := bridge_path_first_scanline(minimum, 0, step)
	if !line_ok {error = .Arithmetic; return}
	mask_path_index: u64
	for line < maximum {
		if scanline_count >= limits.max_scanlines {
			error = .Scanline_Limit
			return
		}
		scanline_index := scanline_count
		scanline_count += 1
		hit_count, hit_error := bridge_path_collect_hits(
			boundary,
			direction_x,
			direction_y,
			normal_x,
			normal_y,
			line,
			scratch_hits,
		)
		if hit_error != .None {
			error = solid_path_bridge_error(hit_error)
			return
		}
		if hit_count&1 != 0 {
			error = .Odd_Intersection_Count
			return
		}
		for hit_index := 0; hit_index < hit_count; hit_index += 2 {
			first := scratch_hits[hit_index]
			second := scratch_hits[hit_index+1]
			if first.point == second.point {continue}
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
				path_set_id := contracts.stable_id_child(
					mask.stable_id,
					.Feature,
					0,
				)
				paths[write_index] = {
					stable_id = contracts.stable_id_child(
						path_set_id,
						.Path,
						mask_path_index,
					),
					path_set_id = path_set_id,
					overlap_mask_id = mask.stable_id,
					overlap_mask_index = mask_index,
					layer_index = mask.layer_index,
					role = mask.role,
					angle = angle,
					direction_x = direction_x,
					direction_y = direction_y,
					mask_path_index = mask_path_index,
					scanline_index = scanline_index,
					line_coordinate_scaled = line,
					line_width = line_width,
					point_a = first.point,
					point_b = second.point,
					hit_offset = write_index*2,
				}
				output_hits[write_index*2] =
					bridge_path_output_hit(first)
				output_hits[write_index*2+1] =
					bridge_path_output_hit(second)
			}
			path_count += 1
			mask_path_index += 1
		}
		if line > max(i128)-step {break}
		line += step
	}
	return
}

solid_path_layer_angle :: proc(
	base, step: profiles.Angle_Millidegrees,
	layer_index: u32,
) -> profiles.Angle_Millidegrees {
	value := (
		i64(i32(base))+
		i64(layer_index)*i64(i32(step))
	)%180_000
	return profiles.Angle_Millidegrees(i32(value))
}

solid_path_role_is_skin :: proc(role: profiles.Printable_Role) -> bool {
	return role == .Bottom_Skin ||
		role == .Top_Skin ||
		role == .Top_Bottom_Skin
}

solid_path_overlap_valid :: proc(overlap: Role_Overlap_Result) -> bool {
	if overlap.policy != .Subtract_Higher_Priority ||
	   !role_overlap_fill_rule_valid(overlap.fill_rule) {
		return false
	}
	expected_mask_offset: u64
	expected_path_offset: u64
	for layer, layer_index in overlap.layers {
		if layer.mask_offset != expected_mask_offset ||
		   layer.path_offset != expected_path_offset ||
		   layer.mask_offset+u64(layer.mask_count) >
			u64(len(overlap.masks)) ||
		   layer.path_offset+u64(layer.path_count) >
			u64(len(overlap.paths)) {
			return false
		}
		mask_start := int(layer.mask_offset)
		mask_end := mask_start+int(layer.mask_count)
		for mask in overlap.masks[mask_start:mask_end] {
			if mask.layer_index != u32(layer_index) ||
			   mask.path_offset != expected_path_offset ||
			   mask.path_offset+u64(mask.path_count) >
				u64(len(overlap.paths)) ||
			   mask.point_offset+u64(mask.point_count) >
				u64(len(overlap.points)) {
				return false
			}
			expected_path_offset += u64(mask.path_count)
		}
		if expected_path_offset !=
		   layer.path_offset+u64(layer.path_count) {
			return false
		}
		expected_mask_offset += u64(layer.mask_count)
	}
	return expected_mask_offset == u64(len(overlap.masks)) &&
		expected_path_offset == u64(len(overlap.paths))
}

solid_path_bridge_error :: proc(
	error: Bridge_Path_Error,
) -> Solid_Path_Error {
	#partial switch error {
	case .Odd_Intersection_Count: return .Odd_Intersection_Count
	case .Allocation_Failed:      return .Allocation_Failed
	case .Arithmetic:             return .Arithmetic
	}
	return .Invalid_Input
}

solid_path_overlap_error :: proc(
	error: Role_Overlap_Error,
) -> Solid_Path_Error {
	#partial switch error {
	case .Allocation_Failed: return .Allocation_Failed
	case .Arithmetic:        return .Arithmetic
	}
	return .Invalid_Input
}

solid_path_result_destroy :: proc(
	result: ^Solid_Path_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.paths, allocator)
	delete(result.hits, allocator)
	result^ = {}
}
