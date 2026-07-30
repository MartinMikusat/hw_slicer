package features

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"

Unified_Path_Source_Layer :: struct {
	source_offset: u64,
	source_count:  u32,
	point_offset:  u64,
	point_count:   u32,
}

Unified_Path_Source_Result :: struct {
	inner_perimeters_first: bool,
	nominal_line_width:     contracts.Micrometres,
	layers:                 []Unified_Path_Source_Layer,
	sources:                []Unified_Path_Source,
	points:                 []polygon.Polygon_Point,
	line_widths:            []contracts.Micrometres,
}

Unified_Path_Source_Limits :: struct {
	max_sources: u64,
	max_points:  u64,
}

DEFAULT_UNIFIED_PATH_SOURCE_LIMITS :: Unified_Path_Source_Limits{
	max_sources = 1_000_000_000,
	max_points = 4_000_000_000,
}

Unified_Path_Source_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Source_Limit,
	Point_Limit,
	Allocation_Failed,
	Arithmetic,
}

unified_path_sources_build :: proc(
	layer_ids: []contracts.Stable_ID,
	perimeters: Perimeter_Result,
	bridges: Bridge_Path_Result,
	gaps: Gap_Centerline_Result,
	solids: Solid_Path_Result,
	infill: Infill_Result,
	supports: Support_Path_Result,
	process: profiles.Resolved_Process_Profile,
	inner_perimeters_first: bool,
	limits := DEFAULT_UNIFIED_PATH_SOURCE_LIMITS,
	allocator := context.allocator,
) -> (Unified_Path_Source_Result, Unified_Path_Source_Error) {
	layer_count := len(layer_ids)
	if i64(process.source.nominal_line_width) <= 0 ||
	   i64(process.source.nominal_line_width) >
		geometry.MAX_PLANAR_COORDINATE_UM {
		return {}, .Invalid_Config
	}
	if len(perimeters.layers) != layer_count ||
	   len(bridges.layers) != layer_count ||
	   len(gaps.layers) != layer_count ||
	   len(solids.layers) != layer_count ||
	   len(infill.layers) != layer_count ||
	   len(supports.layers) != layer_count ||
	   !unified_path_source_ranges_valid(
			perimeters,
			bridges,
			gaps,
			solids,
			infill,
			supports,
	   ) {
		return {}, .Invalid_Input
	}
	source_count_128 :=
		u128(len(perimeters.paths))+
		u128(len(bridges.paths))+
		u128(len(gaps.paths))+
		u128(len(solids.paths))+
		u128(len(infill.segments))+
		u128(len(supports.paths))
	if source_count_128 > u128(limits.max_sources) {
		return {}, .Source_Limit
	}
	point_count_128 :=
		u128(len(perimeters.points))+
		u128(len(bridges.paths))*2+
		u128(len(gaps.vertices))+
		u128(len(solids.paths))*2+
		u128(len(infill.segments))*2+
		u128(len(supports.paths))*2
	if point_count_128 > u128(limits.max_points) {
		return {}, .Point_Limit
	}
	if source_count_128 > u128(max(int)) ||
	   point_count_128 > u128(max(int)) ||
	   source_count_128 > u128(max(u32)) {
		return {}, .Arithmetic
	}
	source_count := int(source_count_128)
	point_count := int(point_count_128)
	result := Unified_Path_Source_Result{
		inner_perimeters_first = inner_perimeters_first,
		nominal_line_width = process.source.nominal_line_width,
	}
	result.layers = make(
		[]Unified_Path_Source_Layer,
		layer_count,
		allocator,
	)
	result.sources = make(
		[]Unified_Path_Source,
		source_count,
		allocator,
	)
	result.points = make(
		[]polygon.Polygon_Point,
		point_count,
		allocator,
	)
	result.line_widths = make(
		[]contracts.Micrometres,
		point_count,
		allocator,
	)
	if layer_count > 0 && result.layers == nil ||
	   source_count > 0 && result.sources == nil ||
	   point_count > 0 &&
		(result.points == nil || result.line_widths == nil) {
		unified_path_source_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	source_write := 0
	point_write := 0
	for layer_id, layer_index in layer_ids {
		if layer_id == contracts.INVALID_STABLE_ID {
			unified_path_source_result_destroy(&result, allocator)
			return {}, .Invalid_Input
		}
		layer_source_start := source_write
		layer_point_start := point_write
		source_order: u64

		perimeter_layer := perimeters.layers[layer_index]
		group_cursor := int(perimeter_layer.group_offset)
		group_end := group_cursor+int(perimeter_layer.group_count)
		for group_cursor < group_end {
			region_group_end :=
				group_cursor+int(perimeters.config.count)
			if region_group_end > group_end {
				unified_path_source_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			for local_group_index in 0..<int(perimeters.config.count) {
				group_index := group_cursor+local_group_index
				if inner_perimeters_first {
					group_index =
						region_group_end-1-local_group_index
				}
				group := perimeters.groups[group_index]
				if group.layer_index != u32(layer_index) {
					unified_path_source_result_destroy(
						&result,
						allocator,
					)
					return {}, .Invalid_Input
				}
				path_start := int(group.path_offset)
				path_end := path_start+int(group.path_count)
				for path_index in path_start..<path_end {
					path := perimeters.paths[path_index]
					if path.layer_index != u32(layer_index) ||
					   path.region_id != group.region_id ||
					   path.region_index != group.region_index ||
					   path.perimeter_index !=
						group.perimeter_index ||
					   path.point_offset+u64(path.point_count) >
						u64(len(perimeters.points)) {
						unified_path_source_result_destroy(
							&result,
							allocator,
						)
						return {}, .Invalid_Input
					}
					points_start := int(path.point_offset)
					points_end :=
						points_start+int(path.point_count)
					if !unified_path_source_append(
						&result,
						&source_write,
						&point_write,
						path.stable_id,
						layer_id,
						u32(layer_index),
						.Perimeter,
						.Perimeter,
						u32(path_index),
						source_order,
						true,
						perimeters.points[
							points_start:points_end
						],
						nil,
						perimeters.config.line_width,
					) {
						unified_path_source_result_destroy(
							&result,
							allocator,
						)
						return {}, .Invalid_Input
					}
					source_order += 1
				}
			}
			group_cursor = region_group_end
		}

		bridge_layer := bridges.layers[layer_index]
		path_start := int(bridge_layer.path_offset)
		path_end := path_start+int(bridge_layer.path_count)
		source_order = 0
		for path_index in path_start..<path_end {
			path := bridges.paths[path_index]
			if path.layer_index != u32(layer_index) ||
			   path.role != .Bridge {
				unified_path_source_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			points := [2]polygon.Polygon_Point{
				path.point_a,
				path.point_b,
			}
			if !unified_path_source_append(
				&result,
				&source_write,
				&point_write,
				path.stable_id,
				layer_id,
				u32(layer_index),
				.Bridge,
				.Bridge,
				u32(path_index),
				source_order,
				false,
				points[:],
				nil,
				path.line_width,
			) {
				unified_path_source_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			source_order += 1
		}

		gap_layer := gaps.layers[layer_index]
		path_start = int(gap_layer.path_offset)
		path_end = path_start+int(gap_layer.path_count)
		source_order = 0
		for path_index in path_start..<path_end {
			path := gaps.paths[path_index]
			if path.layer_index != u32(layer_index) ||
			   path.vertex_offset+u64(path.vertex_count) >
				u64(len(gaps.vertices)) {
				unified_path_source_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			vertex_start := int(path.vertex_offset)
			vertex_end := vertex_start+int(path.vertex_count)
			if !unified_path_source_append_gap(
				&result,
				&source_write,
				&point_write,
				path,
				layer_id,
				u32(path_index),
				source_order,
				gaps.vertices[vertex_start:vertex_end],
			) {
				unified_path_source_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			source_order += 1
		}

		solid_layer := solids.layers[layer_index]
		path_start = int(solid_layer.path_offset)
		path_end = path_start+int(solid_layer.path_count)
		source_order = 0
		for path_index in path_start..<path_end {
			path := solids.paths[path_index]
			if path.layer_index != u32(layer_index) ||
			   !solid_path_role_is_skin(path.role) {
				unified_path_source_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			points := [2]polygon.Polygon_Point{
				path.point_a,
				path.point_b,
			}
			if !unified_path_source_append(
				&result,
				&source_write,
				&point_write,
				path.stable_id,
				layer_id,
				u32(layer_index),
				path.role,
				.Solid,
				u32(path_index),
				source_order,
				false,
				points[:],
				nil,
				path.line_width,
			) {
				unified_path_source_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			source_order += 1
		}

		infill_layer := infill.layers[layer_index]
		segment_start := int(infill_layer.segment_offset)
		segment_end := segment_start+int(infill_layer.segment_count)
		source_order = 0
		for segment_index in segment_start..<segment_end {
			segment := infill.segments[segment_index]
			if segment.layer_index != u32(layer_index) {
				unified_path_source_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			points := [2]polygon.Polygon_Point{
				segment.point_a,
				segment.point_b,
			}
			if !unified_path_source_append(
				&result,
				&source_write,
				&point_write,
				segment.stable_id,
				layer_id,
				u32(layer_index),
				.Sparse_Infill,
				.Sparse_Infill,
				u32(segment_index),
				source_order,
				false,
				points[:],
				nil,
				process.source.nominal_line_width,
			) {
				unified_path_source_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			source_order += 1
		}

		support_layer := supports.layers[layer_index]
		path_start = int(support_layer.path_offset)
		path_end = path_start+int(support_layer.path_count)
		source_order = 0
		for path_index in path_start..<path_end {
			path := supports.paths[path_index]
			if path.layer_index != u32(layer_index) ||
			   path.role != .Support &&
				path.role != .Support_Interface {
				unified_path_source_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			points := [2]polygon.Polygon_Point{
				path.point_a,
				path.point_b,
			}
			if !unified_path_source_append(
				&result,
				&source_write,
				&point_write,
				path.stable_id,
				layer_id,
				u32(layer_index),
				path.role,
				.Support,
				u32(path_index),
				source_order,
				false,
				points[:],
				nil,
				path.line_width,
			) {
				unified_path_source_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			source_order += 1
		}

		layer_source_count := source_write-layer_source_start
		layer_point_count := point_write-layer_point_start
		if layer_source_count > int(max(u32)) ||
		   layer_point_count > int(max(u32)) {
			unified_path_source_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		result.layers[layer_index] = {
			source_offset = u64(layer_source_start),
			source_count = u32(layer_source_count),
			point_offset = u64(layer_point_start),
			point_count = u32(layer_point_count),
		}
	}
	if source_write != len(result.sources) ||
	   point_write != len(result.points) {
		unified_path_source_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	for source in result.sources {
		_, source_ok := unified_path_source_validate(source, layer_ids)
		if !source_ok {
			unified_path_source_result_destroy(&result, allocator)
			return {}, .Invalid_Input
		}
	}
	return result, .None
}

unified_path_source_append :: proc(
	result: ^Unified_Path_Source_Result,
	source_write, point_write: ^int,
	stable_id, layer_id: contracts.Stable_ID,
	layer_index: u32,
	role: profiles.Printable_Role,
	source_kind: Unified_Path_Source_Kind,
	source_index: u32,
	source_order: u64,
	closed: bool,
	points: []polygon.Polygon_Point,
	widths: []contracts.Micrometres,
	uniform_width: contracts.Micrometres,
) -> bool {
	if source_write^ >= len(result.sources) ||
	   point_write^ > len(result.points) ||
	   len(points) > len(result.points)-point_write^ ||
	   widths != nil && len(widths) != len(points) ||
	   widths == nil && i64(uniform_width) <= 0 {
		return false
	}
	point_start := point_write^
	copy(
		result.points[point_start:point_start+len(points)],
		points,
	)
	if widths == nil {
		for &width in result.line_widths[
		    point_start:point_start+len(points)] {
			width = uniform_width
		}
	} else {
		copy(
			result.line_widths[
				point_start:point_start+len(points)
			],
			widths,
		)
	}
	point_write^ += len(points)
	result.sources[source_write^] = {
		stable_id = stable_id,
		layer_id = layer_id,
		layer_index = layer_index,
		role = role,
		source_kind = source_kind,
		source_index = source_index,
		source_order = source_order,
		closed = closed,
		points = result.points[point_start:point_write^],
		line_widths =
			result.line_widths[point_start:point_write^],
	}
	source_write^ += 1
	return true
}

unified_path_source_append_gap :: proc(
	result: ^Unified_Path_Source_Result,
	source_write, point_write: ^int,
	path: Gap_Centerline_Path,
	layer_id: contracts.Stable_ID,
	source_index: u32,
	source_order: u64,
	vertices: []Gap_Centerline_Vertex,
) -> bool {
	if len(vertices) < 2 ||
	   source_write^ >= len(result.sources) ||
	   point_write^ > len(result.points) ||
	   len(vertices) > len(result.points)-point_write^ {
		return false
	}
	point_start := point_write^
	for vertex in vertices {
		if i64(vertex.line_width) <= 0 {return false}
		result.points[point_write^] = vertex.point
		result.line_widths[point_write^] = vertex.line_width
		point_write^ += 1
	}
	result.sources[source_write^] = {
		stable_id = path.stable_id,
		layer_id = layer_id,
		layer_index = path.layer_index,
		role = path.role,
		source_kind = .Gap_Centerline,
		source_index = source_index,
		source_order = source_order,
		closed = false,
		points = result.points[point_start:point_write^],
		line_widths =
			result.line_widths[point_start:point_write^],
	}
	source_write^ += 1
	return true
}

unified_path_source_ranges_valid :: proc(
	perimeters: Perimeter_Result,
	bridges: Bridge_Path_Result,
	gaps: Gap_Centerline_Result,
	solids: Solid_Path_Result,
	infill: Infill_Result,
	supports: Support_Path_Result,
) -> bool {
	if perimeters.config.count == 0 {return false}
	expected_group_offset: u64
	expected_perimeter_path_offset: u64
	expected_bridge_path_offset: u64
	expected_gap_path_offset: u64
	expected_solid_path_offset: u64
	expected_infill_offset: u64
	expected_support_path_offset: u64
	for _, layer_index in perimeters.layers {
		perimeter_layer := perimeters.layers[layer_index]
		bridge_layer := bridges.layers[layer_index]
		gap_layer := gaps.layers[layer_index]
		solid_layer := solids.layers[layer_index]
		infill_layer := infill.layers[layer_index]
		support_layer := supports.layers[layer_index]
		if perimeter_layer.group_offset != expected_group_offset ||
		   perimeter_layer.path_offset !=
			expected_perimeter_path_offset ||
		   bridge_layer.path_offset != expected_bridge_path_offset ||
		   gap_layer.path_offset != expected_gap_path_offset ||
		   solid_layer.path_offset != expected_solid_path_offset ||
		   infill_layer.segment_offset != expected_infill_offset ||
		   support_layer.path_offset != expected_support_path_offset ||
		   perimeter_layer.group_offset+
			u64(perimeter_layer.group_count) >
			u64(len(perimeters.groups)) ||
		   perimeter_layer.path_offset+
			u64(perimeter_layer.path_count) >
			u64(len(perimeters.paths)) ||
		   bridge_layer.path_offset+u64(bridge_layer.path_count) >
			u64(len(bridges.paths)) ||
		   gap_layer.path_offset+u64(gap_layer.path_count) >
			u64(len(gaps.paths)) ||
		   solid_layer.path_offset+u64(solid_layer.path_count) >
			u64(len(solids.paths)) ||
		   infill_layer.segment_offset+
			u64(infill_layer.segment_count) >
			u64(len(infill.segments)) ||
		   support_layer.path_offset+u64(support_layer.path_count) >
			u64(len(supports.paths)) {
			return false
		}
		expected_group_offset += u64(perimeter_layer.group_count)
		expected_perimeter_path_offset +=
			u64(perimeter_layer.path_count)
		expected_bridge_path_offset += u64(bridge_layer.path_count)
		expected_gap_path_offset += u64(gap_layer.path_count)
		expected_solid_path_offset += u64(solid_layer.path_count)
		expected_infill_offset += u64(infill_layer.segment_count)
		expected_support_path_offset += u64(support_layer.path_count)
	}
	return expected_group_offset == u64(len(perimeters.groups)) &&
		expected_perimeter_path_offset == u64(len(perimeters.paths)) &&
		expected_bridge_path_offset == u64(len(bridges.paths)) &&
		expected_gap_path_offset == u64(len(gaps.paths)) &&
		expected_solid_path_offset == u64(len(solids.paths)) &&
		expected_infill_offset == u64(len(infill.segments)) &&
		expected_support_path_offset == u64(len(supports.paths))
}

unified_path_source_result_destroy :: proc(
	result: ^Unified_Path_Source_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.sources, allocator)
	delete(result.points, allocator)
	delete(result.line_widths, allocator)
	result^ = {}
}
