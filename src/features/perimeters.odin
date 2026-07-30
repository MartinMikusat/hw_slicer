package features

import "core:math"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import slicing "../slicing"

// Keep configuration enums in a full word at provider call boundaries.
Feature_Topology_Policy :: enum u32 {
	Strict_Printable,
	Diagnostic_Closed_Regions,
}

Perimeter_Config :: struct {
	count:         u32,
	line_width:    contracts.Micrometres,
	topology_policy: Feature_Topology_Policy,
	join_type:     polygon.Polygon_Join_Type,
	miter_limit:   f64,
	arc_tolerance: f64,
}

Perimeter_Limits :: struct {
	max_groups: u64,
	max_paths:  u64,
	max_points: u64,
	polygon:    polygon.Polygon_Limits,
}

DEFAULT_PERIMETER_LIMITS :: Perimeter_Limits{
	max_groups = 100_000_000,
	max_paths = 200_000_000,
	max_points = 1_000_000_000,
	polygon = polygon.DEFAULT_POLYGON_LIMITS,
}

Perimeter_Layer :: struct {
	group_offset: u64,
	group_count:  u32,
	path_offset:  u64,
	path_count:   u32,
}

Perimeter_Group :: struct {
	region_id:       contracts.Stable_ID,
	region_index:    u32,
	layer_index:     u32,
	perimeter_index: u32,
	delta:           contracts.Micrometres,
	path_offset:     u64,
	path_count:      u32,
}

Perimeter_Path :: struct {
	stable_id:         contracts.Stable_ID,
	region_id:         contracts.Stable_ID,
	region_index:      u32,
	layer_index:       u32,
	perimeter_index:   u32,
	group_path_index:  u32,
	point_offset:      u64,
	point_count:       u32,
	signed_area_2:     i128,
	winding:           geometry.Predicate_Sign,
}

Perimeter_Result :: struct {
	config: Perimeter_Config,
	layers: []Perimeter_Layer,
	groups: []Perimeter_Group,
	paths:  []Perimeter_Path,
	points: []polygon.Polygon_Point,
}

Perimeter_Error :: enum u8 {
	None,
	Invalid_Config,
	Invalid_Input,
	Group_Limit,
	Path_Limit,
	Point_Limit,
	Provider,
	Allocation_Failed,
	Arithmetic,
}

perimeters_generate :: proc(
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	provider: polygon.Polygon_Provider,
	requested_config: Perimeter_Config,
	limits := DEFAULT_PERIMETER_LIMITS,
	allocator := context.allocator,
) -> (Perimeter_Result, Perimeter_Error) {
	config := requested_config
	if !perimeter_config_valid(config) || provider.offset == nil {
		return {}, .Invalid_Config
	}
	if config.arc_tolerance == 0 {config.arc_tolerance = 0}
	if len(regions.layers) != len(topology.layers) {
		return {}, .Invalid_Input
	}
	_, regions_ok := slicing.region_result_hash(
		contracts.Content_Hash{},
		topology,
		regions,
	)
	if !regions_ok {return {}, .Invalid_Input}
	if config.topology_policy == .Strict_Printable &&
	   (topology.open_chain_count > 0 ||
	    topology.degenerate_loop_count > 0 ||
	    topology.non_manifold_vertex_count > 0) {
		return {}, .Invalid_Input
	}
	if u64(len(regions.layers)) > u64(max(u32)) ||
	   u64(len(regions.regions)) > u64(max(u32)) {
		return {}, .Arithmetic
	}
	group_count_128 := u128(len(regions.regions))*u128(config.count)
	if group_count_128 > u128(limits.max_groups) {
		return {}, .Group_Limit
	}
	if group_count_128 > u128(max(int)) {
		return {}, .Arithmetic
	}
	group_count := int(group_count_128)
	temporary_outputs := make(
		[]polygon.Polygon_Set,
		group_count,
		allocator,
	)
	result := Perimeter_Result{config = config}
	result.layers = make(
		[]Perimeter_Layer,
		len(regions.layers),
		allocator,
	)
	result.groups = make([]Perimeter_Group, group_count, allocator)
	if group_count > 0 &&
	   (temporary_outputs == nil || result.groups == nil) ||
	   len(regions.layers) > 0 && result.layers == nil {
		delete(temporary_outputs, allocator)
		perimeter_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer {
		for &output in temporary_outputs {
			polygon.polygon_set_destroy(&output, allocator)
		}
		delete(temporary_outputs, allocator)
	}

	total_paths: u64
	total_points: u64
	group_write := 0
	for region, region_index in regions.regions {
		input, input_error := perimeter_region_input(
			topology,
			regions,
			u32(region_index),
			allocator,
		)
		if input_error != .None {
			perimeter_result_destroy(&result, allocator)
			return {}, input_error
		}
		for perimeter_index in 0..<config.count {
			delta, delta_ok := perimeter_delta(config, perimeter_index)
			if !delta_ok {
				polygon.polygon_set_destroy(&input, allocator)
				perimeter_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			output_error: polygon.Polygon_Error
			temporary_outputs[group_write], output_error =
				provider.offset(
					input,
					delta,
					config.join_type,
					config.miter_limit,
					config.arc_tolerance,
					limits.polygon,
					allocator,
				)
			if output_error != .None {
				polygon.polygon_set_destroy(&input, allocator)
				perimeter_result_destroy(&result, allocator)
				return {}, .Provider
			}
			output := temporary_outputs[group_write]
			if total_paths > limits.max_paths ||
			   u64(len(output.paths)) >
			   	limits.max_paths-total_paths {
				polygon.polygon_set_destroy(&input, allocator)
				perimeter_result_destroy(&result, allocator)
				return {}, .Path_Limit
			}
			if total_points > limits.max_points ||
			   u64(len(output.points)) >
			   	limits.max_points-total_points {
				polygon.polygon_set_destroy(&input, allocator)
				perimeter_result_destroy(&result, allocator)
				return {}, .Point_Limit
			}
			if u64(len(output.paths)) > u64(max(u32)) {
				polygon.polygon_set_destroy(&input, allocator)
				perimeter_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			result.groups[group_write] = {
				region_id = region.stable_id,
				region_index = u32(region_index),
				layer_index = region.layer_index,
				perimeter_index = perimeter_index,
				delta = delta,
				path_offset = total_paths,
				path_count = u32(len(output.paths)),
			}
			total_paths += u64(len(output.paths))
			total_points += u64(len(output.points))
			group_write += 1
		}
		polygon.polygon_set_destroy(&input, allocator)
	}
	if group_write != group_count ||
	   total_paths > u64(max(int)) ||
	   total_points > u64(max(int)) {
		perimeter_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}

	result.paths = make([]Perimeter_Path, int(total_paths), allocator)
	result.points = make(
		[]polygon.Polygon_Point,
		int(total_points),
		allocator,
	)
	if total_paths > 0 && result.paths == nil ||
	   total_points > 0 && result.points == nil {
		perimeter_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	path_write := 0
	point_write := 0
	for group, group_index in result.groups {
		output := temporary_outputs[group_index]
		for output_path, output_path_index in output.paths {
			if output_path.count > u64(max(u32)) {
				perimeter_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			source_start := int(output_path.offset)
			source_end := source_start+int(output_path.count)
			points := output.points[source_start:source_end]
			area := polygon.polygon_path_area_2(points)
			if area == 0 {
				perimeter_result_destroy(&result, allocator)
				return {}, .Provider
			}
			winding := geometry.Predicate_Sign.Positive
			if area < 0 {winding = .Negative}
			ordinal, ordinal_ok := feature_perimeter_ordinal(
				group.perimeter_index,
				u32(output_path_index),
			)
			if !ordinal_ok {
				perimeter_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			result.paths[path_write] = {
				stable_id = contracts.stable_id_child(
					group.region_id,
					.Feature,
					ordinal,
				),
				region_id = group.region_id,
				region_index = group.region_index,
				layer_index = group.layer_index,
				perimeter_index = group.perimeter_index,
				group_path_index = u32(output_path_index),
				point_offset = u64(point_write),
				point_count = u32(len(points)),
				signed_area_2 = area,
				winding = winding,
			}
			copy(
				result.points[point_write:point_write+len(points)],
				points,
			)
			path_write += 1
			point_write += len(points)
		}
	}
	if path_write != len(result.paths) || point_write != len(result.points) {
		perimeter_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}

	layer_path_offset: u64
	for region_layer, layer_index in regions.layers {
		group_offset := region_layer.region_offset*u64(config.count)
		group_count_for_layer :=
			u64(region_layer.region_count)*u64(config.count)
		if group_count_for_layer > u64(max(u32)) {
			perimeter_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		path_count_for_layer: u64
		if group_count_for_layer > 0 {
			first_group := result.groups[group_offset]
			if first_group.path_offset != layer_path_offset {
				perimeter_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			group_end := group_offset+group_count_for_layer
			for group in result.groups[group_offset:group_end] {
				path_count_for_layer += u64(group.path_count)
			}
		}
		if path_count_for_layer > u64(max(u32)) {
			perimeter_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		result.layers[layer_index] = {
			group_offset = group_offset,
			group_count = u32(group_count_for_layer),
			path_offset = layer_path_offset,
			path_count = u32(path_count_for_layer),
		}
		layer_path_offset += path_count_for_layer
	}
	if layer_path_offset != total_paths {
		perimeter_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

perimeter_region_input :: proc(
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
	region_index: u32,
	allocator := context.allocator,
) -> (polygon.Polygon_Set, Perimeter_Error) {
	if u64(region_index) >= u64(len(regions.regions)) {
		return {}, .Invalid_Input
	}
	region := regions.regions[region_index]
	if region.contour_count == 0 ||
	   region.contour_offset+u64(region.contour_count) >
	   	u64(len(regions.region_contour_indices)) {
		return {}, .Invalid_Input
	}
	point_count: u64
	start := int(region.contour_offset)
	end := start+int(region.contour_count)
	for contour_index in regions.region_contour_indices[start:end] {
		if u64(contour_index) >= u64(len(regions.contours)) {
			return {}, .Invalid_Input
		}
		contour := regions.contours[contour_index]
		if contour.region_index != region_index ||
		   u64(contour.path_index) >= u64(len(topology.paths)) {
			return {}, .Invalid_Input
		}
		path_point_count :=
			u64(topology.paths[contour.path_index].vertex_count)
		if point_count > u64(max(int)) ||
		   path_point_count > u64(max(int))-point_count {
			return {}, .Arithmetic
		}
		point_count += path_point_count
	}
	if point_count > u64(max(int)) {return {}, .Arithmetic}
	result: polygon.Polygon_Set
	result.points = make(
		[]polygon.Polygon_Point,
		int(point_count),
		allocator,
	)
	result.paths = make(
		[]polygon.Polygon_Path,
		int(region.contour_count),
		allocator,
	)
	if result.points == nil || result.paths == nil {
		polygon.polygon_set_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	point_write := 0
	for contour_index, local_contour_index in
	    regions.region_contour_indices[start:end] {
		contour := regions.contours[contour_index]
		path := topology.paths[contour.path_index]
		result.paths[local_contour_index] = {
			offset = u64(point_write),
			count = u64(path.vertex_count),
		}
		for local_point_index in 0..<int(path.vertex_count) {
			source_point_index := local_point_index
			if contour.reverse_path {
				source_point_index =
					int(path.vertex_count)-1-local_point_index
			}
			point := slicing.region_path_point(
				topology,
				path,
				source_point_index,
			)
			result.points[point_write] = {point.x, point.y}
			point_write += 1
		}
	}
	if point_write != len(result.points) {
		polygon.polygon_set_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

perimeter_delta :: proc(
	config: Perimeter_Config,
	perimeter_index: u32,
) -> (contracts.Micrometres, bool) {
	width := i128(i64(config.line_width))
	distance := width/2+i128(perimeter_index)*width
	if distance <= 0 ||
	   distance > i128(geometry.MAX_PLANAR_COORDINATE_UM) {
		return 0, false
	}
	return contracts.Micrometres(-i64(distance)), true
}

perimeter_join_type_valid :: proc(
	join_type: polygon.Polygon_Join_Type,
) -> bool {
	switch join_type {
	case .Square, .Bevel, .Round, .Miter:
		return true
	}
	return false
}

perimeter_config_valid :: proc(config: Perimeter_Config) -> bool {
	return config.count > 0 &&
		config.count <= FEATURE_PERIMETER_COUNT_LIMIT &&
		i64(config.line_width) > 0 &&
		i64(config.line_width)&1 == 0 &&
		i64(config.line_width) <= geometry.MAX_PLANAR_COORDINATE_UM &&
		!math.is_nan(config.miter_limit) &&
		!math.is_inf(config.miter_limit) &&
		!math.is_nan(config.arc_tolerance) &&
		!math.is_inf(config.arc_tolerance) &&
		config.miter_limit >= 1 &&
		config.arc_tolerance >= 0 &&
		(config.topology_policy == .Strict_Printable ||
		 config.topology_policy == .Diagnostic_Closed_Regions) &&
		perimeter_join_type_valid(config.join_type)
}

perimeter_result_destroy :: proc(
	result: ^Perimeter_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.groups, allocator)
	delete(result.paths, allocator)
	delete(result.points, allocator)
	result^ = {}
}
