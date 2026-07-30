package slicing

import "core:mem"

import contracts "../contracts"
import geometry "../geometry"

REGION_INVALID_INDEX :: u32(0xffff_ffff)

Region_Contour_Role :: enum u8 {
	Invalid,
	Outer,
	Hole,
}

Region_Bounds :: struct {
	minimum: Snapped_Point,
	maximum: Snapped_Point,
}

Region_Layer :: struct {
	contour_offset: u64,
	contour_count:  u32,
	region_offset:  u64,
	region_count:   u32,
}

Region_Contour :: struct {
	stable_id:       contracts.Stable_ID,
	path_index:      u32,
	parent_contour:  u32,
	region_index:    u32,
	depth:           u32,
	role:            Region_Contour_Role,
	reverse_path:    bool,
	bounds:          Region_Bounds,
}

Region :: struct {
	stable_id:          contracts.Stable_ID,
	layer_index:        u32,
	outer_contour_index: u32,
	contour_offset:     u64,
	contour_count:      u32,
	filled_area_2:      u128,
	bounds:             Region_Bounds,
}

Region_Result :: struct {
	layers:                 []Region_Layer,
	contours:               []Region_Contour,
	regions:                []Region,
	region_contour_indices: []u32,
	hole_count:             u64,
}

Region_Limits :: struct {
	max_contours:       u64,
	max_regions:        u64,
	max_contour_pairs:  u64,
	max_edge_pair_tests: u64,
}

DEFAULT_REGION_LIMITS :: Region_Limits{
	max_contours = 100_000_000,
	max_regions = 100_000_000,
	max_contour_pairs = 1_000_000_000,
	max_edge_pair_tests = 4_000_000_000,
}

Region_Error :: enum u8 {
	None,
	Invalid_Input,
	Contour_Limit,
	Region_Limit,
	Pair_Test_Limit,
	Contour_Intersection,
	Arithmetic,
	Allocation_Failed,
}

Region_Failure :: struct {
	error:           Region_Error,
	layer_index:     u32,
	contour_index_a: u32,
	contour_index_b: u32,
	path_index_a:    u32,
	path_index_b:    u32,
	edge_index_a:    u32,
	edge_index_b:    u32,
}

Region_Point_Location :: enum u8 {
	Outside,
	Inside,
	Boundary,
}

regions_build :: proc(
	topology: Topology_Result,
	limits := DEFAULT_REGION_LIMITS,
	allocator := context.allocator,
	failure: ^Region_Failure = nil,
) -> (Region_Result, Region_Error) {
	region_failure_reset(failure)
	result, error := regions_build_internal(
		topology,
		limits,
		allocator,
		failure,
	)
	if failure != nil {failure.error = error}
	return result, error
}

regions_build_internal :: proc(
	topology: Topology_Result,
	limits: Region_Limits,
	allocator: mem.Allocator,
	failure: ^Region_Failure,
) -> (Region_Result, Region_Error) {
	if !regions_topology_shape_valid(topology) {
		return {}, .Invalid_Input
	}
	contour_count := 0
	for path in topology.paths {
		if path.kind == .Loop {contour_count += 1}
	}
	if u64(contour_count) > limits.max_contours {
		return {}, .Contour_Limit
	}
	result: Region_Result
	result.layers = make([]Region_Layer, len(topology.layers), allocator)
	result.contours = make([]Region_Contour, contour_count, allocator)
	if len(topology.layers) > 0 && result.layers == nil ||
	   contour_count > 0 && result.contours == nil {
		region_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	if contour_count == 0 {return result, .None}

	contour_write := 0
	for layer, layer_index in topology.layers {
		layer_contour_start := contour_write
		path_end := int(layer.path_offset)+int(layer.path_count)
		for path_index in int(layer.path_offset)..<path_end {
			path := topology.paths[path_index]
			if path.kind != .Loop {continue}
			bounds, bounds_ok := region_path_bounds(topology, path)
			if !bounds_ok {
				region_failure_locate(
					failure,
					u32(layer_index),
					u32(contour_write),
					REGION_INVALID_INDEX,
					u32(path_index),
					REGION_INVALID_INDEX,
				)
				region_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			area, area_error := region_path_area(topology, path)
			if area_error != .None || area != path.signed_area_2 ||
			   area == 0 {
				region_failure_locate(
					failure,
					u32(layer_index),
					u32(contour_write),
					REGION_INVALID_INDEX,
					u32(path_index),
					REGION_INVALID_INDEX,
				)
				region_result_destroy(&result, allocator)
				if area_error != .None {return {}, area_error}
				return {}, .Invalid_Input
			}
			result.contours[contour_write] = {
				stable_id = contracts.stable_id_child(
					path.id,
					.Region_Contour,
					0,
				),
				path_index = u32(path_index),
				parent_contour = REGION_INVALID_INDEX,
				region_index = REGION_INVALID_INDEX,
				bounds = bounds,
			}
			contour_write += 1
		}
		result.layers[layer_index] = {
			contour_offset = u64(layer_contour_start),
			contour_count = u32(contour_write-layer_contour_start),
		}
	}
	if contour_write != contour_count {
		region_result_destroy(&result, allocator)
		return {}, .Invalid_Input
	}

	pair_tests: u64
	edge_pair_tests: u64
	for contour, contour_index in result.contours {
		path := topology.paths[contour.path_index]
		vertex_count := u64(path.vertex_count)
		added_tests: u64
		if vertex_count >= 4 {
			added_tests = vertex_count*(vertex_count-3)/2
		}
		if added_tests > limits.max_edge_pair_tests ||
		   edge_pair_tests >
		   	limits.max_edge_pair_tests-added_tests {
			region_failure_locate(
				failure,
				path.layer_index,
				u32(contour_index),
				REGION_INVALID_INDEX,
				contour.path_index,
				REGION_INVALID_INDEX,
			)
			region_result_destroy(&result, allocator)
			return {}, .Pair_Test_Limit
		}
		edge_pair_tests += added_tests
		self_intersects, left_edge, right_edge, self_error :=
			region_path_self_intersects(topology, path)
		if self_error != .None {
			region_failure_locate_edges(
				failure,
				path.layer_index,
				u32(contour_index),
				u32(contour_index),
				contour.path_index,
				contour.path_index,
				left_edge,
				right_edge,
			)
			region_result_destroy(&result, allocator)
			return {}, self_error
		}
		if self_intersects {
			region_failure_locate_edges(
				failure,
				path.layer_index,
				u32(contour_index),
				u32(contour_index),
				contour.path_index,
				contour.path_index,
				left_edge,
				right_edge,
			)
			region_result_destroy(&result, allocator)
			return {}, .Contour_Intersection
		}
	}
	for layer in result.layers {
		start := int(layer.contour_offset)
		end := start+int(layer.contour_count)
		for left_index in start..<end {
			for right_index in left_index+1..<end {
				if pair_tests >= limits.max_contour_pairs {
					region_failure_locate(
						failure,
						topology.paths[
							result.contours[left_index].path_index
						].layer_index,
						u32(left_index),
						u32(right_index),
						result.contours[left_index].path_index,
						result.contours[right_index].path_index,
					)
					region_result_destroy(&result, allocator)
					return {}, .Pair_Test_Limit
				}
				pair_tests += 1
				left := result.contours[left_index]
				right := result.contours[right_index]
				if !region_bounds_overlap(left.bounds, right.bounds) {
					continue
				}
				left_path := topology.paths[left.path_index]
				right_path := topology.paths[right.path_index]
				added_tests :=
					u64(left_path.vertex_count)*
					u64(right_path.vertex_count)
				if added_tests > limits.max_edge_pair_tests ||
				   edge_pair_tests >
				   	limits.max_edge_pair_tests-added_tests {
					region_failure_locate(
						failure,
						left_path.layer_index,
						u32(left_index),
						u32(right_index),
						left.path_index,
						right.path_index,
					)
					region_result_destroy(&result, allocator)
					return {}, .Pair_Test_Limit
				}
				edge_pair_tests += added_tests
				intersects, left_edge, right_edge,
				intersection_error :=
					region_paths_intersect(
						topology,
						left_path,
						right_path,
					)
				if intersection_error != .None {
					region_failure_locate_edges(
						failure,
						left_path.layer_index,
						u32(left_index),
						u32(right_index),
						left.path_index,
						right.path_index,
						left_edge,
						right_edge,
					)
					region_result_destroy(&result, allocator)
					return {}, intersection_error
				}
				if intersects {
					region_failure_locate_edges(
						failure,
						left_path.layer_index,
						u32(left_index),
						u32(right_index),
						left.path_index,
						right.path_index,
						left_edge,
						right_edge,
					)
					region_result_destroy(&result, allocator)
					return {}, .Contour_Intersection
				}
			}
		}
	}

	for layer in result.layers {
		start := int(layer.contour_offset)
		end := start+int(layer.contour_count)
		for child_index in start..<end {
			child := &result.contours[child_index]
			child_path := topology.paths[child.path_index]
			child_area := region_area_magnitude(child_path.signed_area_2)
			parent_area := max(u128)
			for candidate_index in start..<end {
				if candidate_index == child_index {continue}
				candidate := result.contours[candidate_index]
				candidate_path := topology.paths[candidate.path_index]
				candidate_area :=
					region_area_magnitude(candidate_path.signed_area_2)
				if candidate_area <= child_area ||
				   candidate_area >= parent_area ||
				   !region_bounds_contains(
						candidate.bounds,
						child.bounds,
					) {
					continue
				}
				point := region_path_point(topology, child_path, 0)
				location, location_error :=
					region_point_in_path(
						topology,
						candidate_path,
						point,
					)
				if location_error != .None {
					region_result_destroy(&result, allocator)
					return {}, location_error
				}
				if location == .Boundary {
					region_failure_locate(
						failure,
						child_path.layer_index,
						u32(child_index),
						u32(candidate_index),
						child.path_index,
						candidate.path_index,
					)
					region_result_destroy(&result, allocator)
					return {}, .Contour_Intersection
				}
				if location == .Inside {
					child.parent_contour = u32(candidate_index)
					parent_area = candidate_area
				}
			}
		}
	}

	region_count := 0
	for contour_index in 0..<len(result.contours) {
		depth: u32
		parent := result.contours[contour_index].parent_contour
		for parent != REGION_INVALID_INDEX {
			if u64(parent) >= u64(len(result.contours)) ||
			   depth >= u32(len(result.contours)) {
				region_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			depth += 1
			parent = result.contours[parent].parent_contour
		}
		result.contours[contour_index].depth = depth
		if depth&1 == 0 {
			result.contours[contour_index].role = .Outer
			region_count += 1
		} else {
			result.contours[contour_index].role = .Hole
			result.hole_count += 1
		}
		path := topology.paths[
			result.contours[contour_index].path_index
		]
		result.contours[contour_index].reverse_path =
			depth&1 == 0 && path.winding == .Negative ||
			depth&1 == 1 && path.winding == .Positive
	}
	if u64(region_count) > limits.max_regions {
		region_result_destroy(&result, allocator)
		return {}, .Region_Limit
	}
	result.regions = make([]Region, region_count, allocator)
	result.region_contour_indices = make(
		[]u32,
		contour_count,
		allocator,
	)
	region_counts := make([]u64, region_count, allocator)
	region_writes := make([]u64, region_count, allocator)
	if region_count > 0 &&
	   (result.regions == nil ||
	    result.region_contour_indices == nil ||
	    region_counts == nil || region_writes == nil) {
		delete(region_counts, allocator)
		delete(region_writes, allocator)
		region_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(region_counts, allocator)
	defer delete(region_writes, allocator)

	region_write := 0
	for contour, contour_index in result.contours {
		if contour.role != .Outer {continue}
		path := topology.paths[contour.path_index]
		result.contours[contour_index].region_index = u32(region_write)
		result.regions[region_write] = {
			stable_id = contracts.stable_id_child(
				path.id,
				.Region,
				0,
			),
			layer_index = path.layer_index,
			outer_contour_index = u32(contour_index),
			filled_area_2 =
				region_area_magnitude(path.signed_area_2),
			bounds = contour.bounds,
		}
		region_counts[region_write] = 1
		region_write += 1
	}
	if region_write != region_count {
		region_result_destroy(&result, allocator)
		return {}, .Invalid_Input
	}
	for contour, contour_index in result.contours {
		if contour.role != .Hole {continue}
		if contour.parent_contour == REGION_INVALID_INDEX {
			region_result_destroy(&result, allocator)
			return {}, .Invalid_Input
		}
		parent := result.contours[contour.parent_contour]
		if parent.role != .Outer ||
		   parent.region_index == REGION_INVALID_INDEX {
			region_result_destroy(&result, allocator)
			return {}, .Invalid_Input
		}
		result.contours[contour_index].region_index = parent.region_index
		region_counts[parent.region_index] += 1
		path := topology.paths[contour.path_index]
		hole_area := region_area_magnitude(path.signed_area_2)
		region := &result.regions[parent.region_index]
		if hole_area >= region.filled_area_2 {
			region_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		region.filled_area_2 -= hole_area
	}
	contour_offset: u64
	for &region, region_index in result.regions {
		region.contour_offset = contour_offset
		region.contour_count = u32(region_counts[region_index])
		region_writes[region_index] = contour_offset
		contour_offset += region_counts[region_index]
	}
	if contour_offset != u64(contour_count) {
		region_result_destroy(&result, allocator)
		return {}, .Invalid_Input
	}
	for region, region_index in result.regions {
		write_index := region_writes[region_index]
		result.region_contour_indices[write_index] =
			region.outer_contour_index
		region_writes[region_index] += 1
	}
	for contour, contour_index in result.contours {
		if contour.role != .Hole {continue}
		region_index := contour.region_index
		write_index := region_writes[region_index]
		result.region_contour_indices[write_index] = u32(contour_index)
		region_writes[region_index] += 1
	}
	region_cursor := 0
	for &layer, layer_index in result.layers {
		layer.region_offset = u64(region_cursor)
		for region_cursor < len(result.regions) &&
		    result.regions[region_cursor].layer_index == u32(layer_index) {
			region_cursor += 1
		}
		layer.region_count = u32(
			u64(region_cursor)-layer.region_offset,
		)
	}
	if region_cursor != len(result.regions) {
		region_result_destroy(&result, allocator)
		return {}, .Invalid_Input
	}
	return result, .None
}

region_point_locate :: proc(
	topology: Topology_Result,
	result: Region_Result,
	region_index: u32,
	point: Snapped_Point,
) -> (Region_Point_Location, Region_Error) {
	if u64(region_index) >= u64(len(result.regions)) ||
	   geometry.point_2_validate({x = point.x, y = point.y}) != .None {
		return .Outside, .Invalid_Input
	}
	region := result.regions[region_index]
	if region.contour_count == 0 ||
	   region.contour_offset+u64(region.contour_count) >
	   	u64(len(result.region_contour_indices)) {
		return .Outside, .Invalid_Input
	}
	start := int(region.contour_offset)
	end := start+int(region.contour_count)
	outer_index := result.region_contour_indices[start]
	if outer_index != region.outer_contour_index ||
	   u64(outer_index) >= u64(len(result.contours)) {
		return .Outside, .Invalid_Input
	}
	outer := result.contours[outer_index]
	if outer.role != .Outer ||
	   u64(outer.path_index) >= u64(len(topology.paths)) {
		return .Outside, .Invalid_Input
	}
	location, error := region_point_in_path(
		topology,
		topology.paths[outer.path_index],
		point,
	)
	if error != .None || location != .Inside {
		return location, error
	}
	for member_index in start+1..<end {
		contour_index := result.region_contour_indices[member_index]
		if u64(contour_index) >= u64(len(result.contours)) {
			return .Outside, .Invalid_Input
		}
		contour := result.contours[contour_index]
		if contour.role != .Hole ||
		   contour.region_index != region_index ||
		   u64(contour.path_index) >= u64(len(topology.paths)) {
			return .Outside, .Invalid_Input
		}
		location, error = region_point_in_path(
			topology,
			topology.paths[contour.path_index],
			point,
		)
		if error != .None {return .Outside, error}
		if location == .Boundary {return .Boundary, .None}
		if location == .Inside {return .Outside, .None}
	}
	return .Inside, .None
}

regions_topology_shape_valid :: proc(topology: Topology_Result) -> bool {
	expected_path_offset: u64
	expected_vertex_offset: u64
	for layer, layer_index in topology.layers {
		if layer.path_offset != expected_path_offset ||
		   layer.path_offset+u64(layer.path_count) >
		   	u64(len(topology.paths)) {
			return false
		}
		path_start := int(layer.path_offset)
		path_end := path_start+int(layer.path_count)
		for path in topology.paths[path_start:path_end] {
			if path.layer_index != u32(layer_index) {return false}
		}
		expected_path_offset += u64(layer.path_count)
	}
	if expected_path_offset != u64(len(topology.paths)) {return false}
	for path in topology.paths {
		if path.id == contracts.INVALID_STABLE_ID ||
		   path.vertex_offset != expected_vertex_offset ||
		   path.vertex_offset+u64(path.vertex_count) >
		   	u64(len(topology.path_vertex_indices)) {
			return false
		}
		switch path.kind {
		case .Loop:
			if path.vertex_count < 3 ||
			   path.vertex_count != path.segment_count ||
			   path.signed_area_2 == 0 ||
			   path.winding == .Zero ||
			   path.signed_area_2 < 0 &&
			   	path.winding != .Negative ||
			   path.signed_area_2 > 0 &&
			   	path.winding != .Positive {
				return false
			}
		case .Open_Chain, .Degenerate_Loop:
		case .Invalid:
			return false
		}
		expected_vertex_offset += u64(path.vertex_count)
	}
	if expected_vertex_offset != u64(len(topology.path_vertex_indices)) {
		return false
	}
	for index in topology.path_vertex_indices {
		if u64(index) >= u64(len(topology.vertices)) {return false}
	}
	return true
}

region_path_bounds :: proc(
	topology: Topology_Result,
	path: Topology_Path,
) -> (Region_Bounds, bool) {
	if path.vertex_count == 0 {return {}, false}
	first := region_path_point(topology, path, 0)
	if geometry.point_2_validate({x = first.x, y = first.y}) != .None {
		return {}, false
	}
	bounds := Region_Bounds{minimum = first, maximum = first}
	for local_index in 1..<int(path.vertex_count) {
		point := region_path_point(topology, path, local_index)
		if geometry.point_2_validate({x = point.x, y = point.y}) !=
		   .None {
			return {}, false
		}
		bounds.minimum.x = min(bounds.minimum.x, point.x)
		bounds.minimum.y = min(bounds.minimum.y, point.y)
		bounds.maximum.x = max(bounds.maximum.x, point.x)
		bounds.maximum.y = max(bounds.maximum.y, point.y)
	}
	return bounds, true
}

region_path_area :: proc(
	topology: Topology_Result,
	path: Topology_Path,
) -> (i128, Region_Error) {
	area: i128
	for local_index in 0..<int(path.vertex_count) {
		a := region_path_point(topology, path, local_index)
		b := region_path_point(
			topology,
			path,
			(local_index+1)%int(path.vertex_count),
		)
		area += i128(i64(a.x))*i128(i64(b.y))-
			i128(i64(a.y))*i128(i64(b.x))
	}
	return area, .None
}

region_path_point :: proc(
	topology: Topology_Result,
	path: Topology_Path,
	local_index: int,
) -> Snapped_Point {
	path_index := int(path.vertex_offset)+local_index
	vertex_index := topology.path_vertex_indices[path_index]
	return topology.vertices[vertex_index].point
}

region_paths_intersect :: proc(
	topology: Topology_Result,
	left, right: Topology_Path,
) -> (bool, u32, u32, Region_Error) {
	for left_index in 0..<int(left.vertex_count) {
		a := region_path_point(topology, left, left_index)
		b := region_path_point(
			topology,
			left,
			(left_index+1)%int(left.vertex_count),
		)
		for right_index in 0..<int(right.vertex_count) {
			c := region_path_point(topology, right, right_index)
			d := region_path_point(
				topology,
				right,
				(right_index+1)%int(right.vertex_count),
			)
			intersects, error := region_segments_intersect(a, b, c, d)
			if error != .None {
				return false, u32(left_index), u32(right_index), error
			}
			if intersects {
				return true, u32(left_index), u32(right_index), .None
			}
		}
	}
	return false, REGION_INVALID_INDEX, REGION_INVALID_INDEX, .None
}

region_path_self_intersects :: proc(
	topology: Topology_Result,
	path: Topology_Path,
) -> (bool, u32, u32, Region_Error) {
	vertex_count := int(path.vertex_count)
	for left_index in 0..<vertex_count {
		left_next := (left_index+1)%vertex_count
		a := region_path_point(topology, path, left_index)
		b := region_path_point(topology, path, left_next)
		for right_index in left_index+1..<vertex_count {
			right_next := (right_index+1)%vertex_count
			if right_index == left_next || right_next == left_index {
				continue
			}
			c := region_path_point(topology, path, right_index)
			d := region_path_point(topology, path, right_next)
			intersects, error := region_segments_intersect(a, b, c, d)
			if error != .None {
				return false, u32(left_index), u32(right_index), error
			}
			if intersects {
				return true, u32(left_index), u32(right_index), .None
			}
		}
	}
	return false, REGION_INVALID_INDEX, REGION_INVALID_INDEX, .None
}

region_segments_intersect :: proc(
	a, b, c, d: Snapped_Point,
) -> (bool, Region_Error) {
	if max(a.x, b.x) < min(c.x, d.x) ||
	   max(c.x, d.x) < min(a.x, b.x) ||
	   max(a.y, b.y) < min(c.y, d.y) ||
	   max(c.y, d.y) < min(a.y, b.y) {
		return false, .None
	}
	o0, error := region_orient(a, b, c)
	if error != .None {return false, error}
	o1: geometry.Predicate_Sign
	o1, error = region_orient(a, b, d)
	if error != .None {return false, error}
	o2: geometry.Predicate_Sign
	o2, error = region_orient(c, d, a)
	if error != .None {return false, error}
	o3: geometry.Predicate_Sign
	o3, error = region_orient(c, d, b)
	if error != .None {return false, error}
	if o0 == .Zero && region_point_on_segment(c, a, b) ||
	   o1 == .Zero && region_point_on_segment(d, a, b) ||
	   o2 == .Zero && region_point_on_segment(a, c, d) ||
	   o3 == .Zero && region_point_on_segment(b, c, d) {
		return true, .None
	}
	return region_signs_opposite(o0, o1) &&
		region_signs_opposite(o2, o3),
		.None
}

region_signs_opposite :: proc(
	a, b: geometry.Predicate_Sign,
) -> bool {
	return a == .Negative && b == .Positive ||
		a == .Positive && b == .Negative
}

region_point_in_path :: proc(
	topology: Topology_Result,
	path: Topology_Path,
	point: Snapped_Point,
) -> (Region_Point_Location, Region_Error) {
	inside := false
	for local_index in 0..<int(path.vertex_count) {
		a := region_path_point(topology, path, local_index)
		b := region_path_point(
			topology,
			path,
			(local_index+1)%int(path.vertex_count),
		)
		orientation, error := region_orient(a, b, point)
		if error != .None {return .Outside, error}
		if orientation == .Zero && region_point_on_segment(point, a, b) {
			return .Boundary, .None
		}
		crosses_y := (a.y > point.y) != (b.y > point.y)
		if !crosses_y {continue}
		if b.y > a.y && orientation == .Positive ||
		   b.y < a.y && orientation == .Negative {
			inside = !inside
		}
	}
	if inside {return .Inside, .None}
	return .Outside, .None
}

region_orient :: proc(
	a, b, c: Snapped_Point,
) -> (geometry.Predicate_Sign, Region_Error) {
	_, sign, error := geometry.orient_2d_checked(
		{x = a.x, y = a.y},
		{x = b.x, y = b.y},
		{x = c.x, y = c.y},
	)
	if error != .None {return .Zero, .Arithmetic}
	return sign, .None
}

region_point_on_segment :: proc(
	point, a, b: Snapped_Point,
) -> bool {
	return point.x >= min(a.x, b.x) && point.x <= max(a.x, b.x) &&
		point.y >= min(a.y, b.y) && point.y <= max(a.y, b.y)
}

region_bounds_overlap :: proc(a, b: Region_Bounds) -> bool {
	return a.minimum.x <= b.maximum.x &&
		b.minimum.x <= a.maximum.x &&
		a.minimum.y <= b.maximum.y &&
		b.minimum.y <= a.maximum.y
}

region_bounds_contains :: proc(
	outer, inner: Region_Bounds,
) -> bool {
	return outer.minimum.x <= inner.minimum.x &&
		outer.minimum.y <= inner.minimum.y &&
		outer.maximum.x >= inner.maximum.x &&
		outer.maximum.y >= inner.maximum.y
}

region_area_magnitude :: proc(area: i128) -> u128 {
	if area < 0 {return u128(-(area+1))+1}
	return u128(area)
}

region_failure_reset :: proc(failure: ^Region_Failure) {
	if failure == nil {return}
	failure^ = {
		layer_index = REGION_INVALID_INDEX,
		contour_index_a = REGION_INVALID_INDEX,
		contour_index_b = REGION_INVALID_INDEX,
		path_index_a = REGION_INVALID_INDEX,
		path_index_b = REGION_INVALID_INDEX,
		edge_index_a = REGION_INVALID_INDEX,
		edge_index_b = REGION_INVALID_INDEX,
	}
}

region_failure_locate :: proc(
	failure: ^Region_Failure,
	layer_index, contour_index_a, contour_index_b: u32,
	path_index_a, path_index_b: u32,
) {
	if failure == nil {return}
	failure.layer_index = layer_index
	failure.contour_index_a = contour_index_a
	failure.contour_index_b = contour_index_b
	failure.path_index_a = path_index_a
	failure.path_index_b = path_index_b
}

region_failure_locate_edges :: proc(
	failure: ^Region_Failure,
	layer_index, contour_index_a, contour_index_b: u32,
	path_index_a, path_index_b, edge_index_a, edge_index_b: u32,
) {
	region_failure_locate(
		failure,
		layer_index,
		contour_index_a,
		contour_index_b,
		path_index_a,
		path_index_b,
	)
	if failure == nil {return}
	failure.edge_index_a = edge_index_a
	failure.edge_index_b = edge_index_b
}

region_result_destroy :: proc(
	result: ^Region_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.contours, allocator)
	delete(result.regions, allocator)
	delete(result.region_contour_indices, allocator)
	result^ = {}
}
