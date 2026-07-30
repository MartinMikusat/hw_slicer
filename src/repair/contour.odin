package repair

import "core:mem"
import "core:slice"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import slicing "../slicing"

Contour_Repair_Request :: struct {
	failure:           slicing.Region_Failure,
	fill_rule:         polygon.Polygon_Fill_Rule,
	lineage_tolerance: contracts.Micrometres,
}

Contour_Repair_Limits :: struct {
	max_lineage_tests: u64,
	max_sources:       u64,
	polygon:           polygon.Polygon_Limits,
}

DEFAULT_CONTOUR_REPAIR_LIMITS :: Contour_Repair_Limits{
	max_lineage_tests = 1_000_000_000,
	max_sources = 1_000_000_000,
	polygon = polygon.DEFAULT_POLYGON_LIMITS,
}

Contour_Repair_Source :: struct {
	path_id:              contracts.Stable_ID,
	path_index:           u32,
	edge_index:           u32,
	segment_index:        u32,
	maximum_deviation_um: u64,
}

Contour_Repair_Edge :: struct {
	output_path_index: u32,
	output_edge_index: u32,
	source_offset:     u64,
	source_count:      u32,
}

Contour_Repair_Result :: struct {
	source_path_id:          contracts.Stable_ID,
	source_path_index:       u32,
	layer_index:             u32,
	failure_edge_a:          u32,
	failure_edge_b:          u32,
	fill_rule:               polygon.Polygon_Fill_Rule,
	lineage_tolerance_um:    contracts.Micrometres,
	output:                  polygon.Polygon_Set,
	edges:                   []Contour_Repair_Edge,
	sources:                 []Contour_Repair_Source,
	lineage_test_count:      u64,
	multi_source_edge_count: u64,
	maximum_deviation_um:    u64,
}

Contour_Repair_Error :: enum u8 {
	None,
	Invalid_Input,
	Not_Self_Intersection,
	Lineage_Limit,
	Lineage_Incomplete,
	Provider,
	Allocation_Failed,
	Arithmetic,
}

Contour_Lineage_Match :: struct {
	source:   Contour_Repair_Source,
	start:    i128,
	end:      i128,
}

contour_path_repair :: proc(
	topology: slicing.Topology_Result,
	provider: polygon.Polygon_Provider,
	request: Contour_Repair_Request,
	limits := DEFAULT_CONTOUR_REPAIR_LIMITS,
	allocator := context.allocator,
) -> (Contour_Repair_Result, Contour_Repair_Error) {
	failure := request.failure
	if !slicing.regions_topology_shape_valid(topology) ||
	   failure.error != .Contour_Intersection ||
	   failure.path_index_a != failure.path_index_b ||
	   failure.contour_index_a != failure.contour_index_b ||
	   u64(failure.path_index_a) >= u64(len(topology.paths)) ||
	   i64(request.lineage_tolerance) < 0 ||
	   i64(request.lineage_tolerance) >
	   	geometry.MAX_PLANAR_COORDINATE_UM ||
	   provider.boolean == nil {
		return {}, .Invalid_Input
	}
	path := topology.paths[failure.path_index_a]
	if path.kind != .Loop || path.layer_index != failure.layer_index ||
	   path.segment_count != path.vertex_count ||
	   path.segment_offset+u64(path.segment_count) >
	   	u64(len(topology.path_segment_indices)) {
		return {}, .Invalid_Input
	}
	self_intersects, edge_a, edge_b, region_error :=
		slicing.region_path_self_intersects(topology, path)
	if region_error != .None {return {}, .Arithmetic}
	if !self_intersects || edge_a != failure.edge_index_a ||
	   edge_b != failure.edge_index_b {
		return {}, .Not_Self_Intersection
	}

	input_points := make(
		[]polygon.Polygon_Point,
		int(path.vertex_count),
		allocator,
	)
	if input_points == nil {return {}, .Allocation_Failed}
	defer delete(input_points, allocator)
	for &point, local_index in input_points {
		source := slicing.region_path_point(
			topology,
			path,
			local_index,
		)
		point = {source.x, source.y}
	}
	input_path := [1]polygon.Polygon_Path{{0, u64(len(input_points))}}
	empty: polygon.Polygon_Set
	output, provider_error := provider.boolean(
		{input_points, input_path[:]},
		empty,
		.Union,
		request.fill_rule,
		limits.polygon,
		allocator,
	)
	if provider_error != .None {return {}, .Provider}

	result := Contour_Repair_Result{
		source_path_id = path.id,
		source_path_index = failure.path_index_a,
		layer_index = path.layer_index,
		failure_edge_a = edge_a,
		failure_edge_b = edge_b,
		fill_rule = request.fill_rule,
		lineage_tolerance_um = request.lineage_tolerance,
		output = output,
	}
	if len(output.points) == 0 {
		contour_repair_result_destroy(&result, allocator)
		return {}, .Lineage_Incomplete
	}
	result.edges = make(
		[]Contour_Repair_Edge,
		len(output.points),
		allocator,
	)
	matches := make(
		[]Contour_Lineage_Match,
		int(path.vertex_count),
		allocator,
	)
	if result.edges == nil || matches == nil {
		delete(matches, allocator)
		contour_repair_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(matches, allocator)

	source_count: u64
	edge_write := 0
	for output_path, output_path_index in output.paths {
		for output_edge_index in 0..<int(output_path.count) {
			match_count, lineage_error := contour_lineage_matches(
				topology,
				path,
				failure.path_index_a,
				output,
				u32(output_path_index),
				u32(output_edge_index),
				request.lineage_tolerance,
				matches,
				&result.lineage_test_count,
				limits.max_lineage_tests,
			)
			if lineage_error != .None {
				contour_repair_result_destroy(&result, allocator)
				return {}, lineage_error
			}
			if source_count > limits.max_sources ||
			   u64(match_count) > limits.max_sources-source_count {
				contour_repair_result_destroy(&result, allocator)
				return {}, .Lineage_Limit
			}
			result.edges[edge_write] = {
				output_path_index = u32(output_path_index),
				output_edge_index = u32(output_edge_index),
				source_offset = source_count,
				source_count = u32(match_count),
			}
			if match_count > 1 {result.multi_source_edge_count += 1}
			for match in matches[:match_count] {
				result.maximum_deviation_um = max(
					result.maximum_deviation_um,
					match.source.maximum_deviation_um,
				)
			}
			source_count += u64(match_count)
			edge_write += 1
		}
	}
	if edge_write != len(result.edges) ||
	   source_count > u64(max(int)) {
		contour_repair_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	result.sources = make(
		[]Contour_Repair_Source,
		int(source_count),
		allocator,
	)
	if result.sources == nil {
		contour_repair_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	source_write := 0
	for edge in result.edges {
		match_count, lineage_error := contour_lineage_matches(
			topology,
			path,
			failure.path_index_a,
			output,
			edge.output_path_index,
			edge.output_edge_index,
			request.lineage_tolerance,
			matches,
			nil,
			limits.max_lineage_tests,
		)
		if lineage_error != .None ||
		   match_count != int(edge.source_count) {
			contour_repair_result_destroy(&result, allocator)
			if lineage_error != .None {return {}, lineage_error}
			return {}, .Arithmetic
		}
		for match in matches[:match_count] {
			result.sources[source_write] = match.source
			source_write += 1
		}
	}
	if source_write != len(result.sources) {
		contour_repair_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

contour_lineage_matches :: proc(
	topology: slicing.Topology_Result,
	source_path: slicing.Topology_Path,
	source_path_index: u32,
	output: polygon.Polygon_Set,
	output_path_index, output_edge_index: u32,
	tolerance: contracts.Micrometres,
	matches: []Contour_Lineage_Match,
	test_count: ^u64,
	maximum_tests: u64,
) -> (int, Contour_Repair_Error) {
	if u64(output_path_index) >= u64(len(output.paths)) {
		return 0, .Invalid_Input
	}
	output_path := output.paths[output_path_index]
	if u64(output_edge_index) >= output_path.count {
		return 0, .Invalid_Input
	}
	output_start := int(output_path.offset)+int(output_edge_index)
	output_end := int(output_path.offset)+
		(int(output_edge_index)+1)%int(output_path.count)
	a := output.points[output_start]
	b := output.points[output_end]
	use_x := contour_absolute_i128(
		i128(i64(b.x))-i128(i64(a.x)),
	) >= contour_absolute_i128(
		i128(i64(b.y))-i128(i64(a.y)),
	)
	output_min, output_max := contour_projection_bounds(a, b, use_x)
	match_count := 0
	for local_edge in 0..<int(source_path.vertex_count) {
		if test_count != nil {
			if test_count^ >= maximum_tests {
				return 0, .Lineage_Limit
			}
			test_count^ += 1
		}
		c_point := slicing.region_path_point(
			topology,
			source_path,
			local_edge,
		)
		d_point := slicing.region_path_point(
			topology,
			source_path,
			(local_edge+1)%int(source_path.vertex_count),
		)
		c := polygon.Polygon_Point{c_point.x, c_point.y}
		d := polygon.Polygon_Point{d_point.x, d_point.y}
		matches_edge, deviation, interval_start, interval_end,
			match_error := contour_edges_share_lineage(
				a,
				b,
				c,
				d,
				tolerance,
				use_x,
				output_min,
				output_max,
			)
		if match_error != .None {return 0, match_error}
		if !matches_edge {continue}
		if match_count >= len(matches) {return 0, .Arithmetic}
		segment_offset := int(source_path.segment_offset)+local_edge
		matches[match_count] = {
			source = {
				path_id = source_path.id,
				path_index = source_path_index,
				edge_index = u32(local_edge),
				segment_index =
					topology.path_segment_indices[segment_offset],
				maximum_deviation_um = deviation,
			},
			start = interval_start,
			end = interval_end,
		}
		match_count += 1
	}
	if match_count == 0 {return 0, .Lineage_Incomplete}
	slice.sort_by(
		matches[:match_count],
		contour_lineage_match_less,
	)
	coverage := output_min
	tolerance_128 := i128(i64(tolerance))
	for match in matches[:match_count] {
		if match.start > coverage+tolerance_128 {
			return 0, .Lineage_Incomplete
		}
		coverage = max(coverage, match.end)
	}
	if coverage < output_max-tolerance_128 {
		return 0, .Lineage_Incomplete
	}
	return match_count, .None
}

contour_edges_share_lineage :: proc(
	a, b, c, d: polygon.Polygon_Point,
	tolerance: contracts.Micrometres,
	use_x: bool,
	output_min, output_max: i128,
) -> (
	matches: bool,
	maximum_deviation: u64,
	interval_start, interval_end: i128,
	error: Contour_Repair_Error,
) {
	deviations: [4]u64
	ok: bool
	deviations[0], ok = contour_point_line_deviation(c, a, b)
	if !ok {error = .Arithmetic; return}
	deviations[1], ok = contour_point_line_deviation(d, a, b)
	if !ok {error = .Arithmetic; return}
	deviations[2], ok = contour_point_line_deviation(a, c, d)
	if !ok {error = .Arithmetic; return}
	deviations[3], ok = contour_point_line_deviation(b, c, d)
	if !ok {error = .Arithmetic; return}
	for deviation in deviations {
		maximum_deviation = max(maximum_deviation, deviation)
	}
	if maximum_deviation > u64(i64(tolerance)) {return}
	source_min, source_max := contour_projection_bounds(c, d, use_x)
	tolerance_128 := i128(i64(tolerance))
	if source_max+tolerance_128 < output_min ||
	   source_min-tolerance_128 > output_max {
		return
	}
	interval_start = max(source_min, output_min)
	interval_end = min(source_max, output_max)
	if interval_end <= interval_start {return}
	matches = true
	return
}

contour_point_line_deviation :: proc(
	point, a, b: polygon.Polygon_Point,
) -> (u64, bool) {
	determinant, _, numeric_error := geometry.orient_2d_checked(
		{a.x, a.y},
		{b.x, b.y},
		{point.x, point.y},
	)
	if numeric_error != .None {return 0, false}
	dx := contour_absolute_i128(i128(i64(b.x))-i128(i64(a.x)))
	dy := contour_absolute_i128(i128(i64(b.y))-i128(i64(a.y)))
	scale := u128(max(dx, dy))
	if scale == 0 {return 0, false}
	magnitude := u128(contour_absolute_i128(determinant))
	return u64((magnitude+scale-1)/scale), true
}

contour_projection_bounds :: proc(
	a, b: polygon.Polygon_Point,
	use_x: bool,
) -> (i128, i128) {
	first, second := i128(i64(a.y)), i128(i64(b.y))
	if use_x {
		first, second = i128(i64(a.x)), i128(i64(b.x))
	}
	return min(first, second), max(first, second)
}

contour_lineage_match_less :: proc(
	a, b: Contour_Lineage_Match,
) -> bool {
	if a.start != b.start {return a.start < b.start}
	if a.end != b.end {return a.end < b.end}
	return a.source.edge_index < b.source.edge_index
}

contour_absolute_i128 :: proc(value: i128) -> i128 {
	if value < 0 {return -value}
	return value
}

contour_repair_result_destroy :: proc(
	result: ^Contour_Repair_Result,
	allocator := context.allocator,
) {
	polygon.polygon_set_destroy(&result.output, allocator)
	delete(result.edges, allocator)
	delete(result.sources, allocator)
	result^ = {}
}
