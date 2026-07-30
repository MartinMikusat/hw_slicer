package slicing

import "core:mem"
import "core:slice"

import contracts "../contracts"
import geometry "../geometry"

Topology_Path_Kind :: enum u8 {
	Invalid,
	Loop,
	Open_Chain,
	Degenerate_Loop,
}

Topology_Vertex :: struct {
	id:          contracts.Stable_ID,
	layer_index: u32,
	point:       Snapped_Point,
	degree:      u32,
}

Topology_Path :: struct {
	id:             contracts.Stable_ID,
	layer_index:    u32,
	kind:           Topology_Path_Kind,
	vertex_offset:  u64,
	vertex_count:   u32,
	segment_offset: u64,
	segment_count:  u32,
	signed_area_2:  i128,
	winding:        geometry.Predicate_Sign,
}

Topology_Layer :: struct {
	vertex_offset: u64,
	vertex_count:  u32,
	path_offset:   u64,
	path_count:    u32,
}

Topology_Result :: struct {
	layers:                    []Topology_Layer,
	vertices:                  []Topology_Vertex,
	paths:                     []Topology_Path,
	path_vertex_indices:       []u32,
	path_segment_indices:      []u32,
	open_chain_count:          u64,
	degenerate_loop_count:     u64,
	non_manifold_vertex_count: u64,
}

Topology_Limits :: struct {
	max_vertices:    u64,
	max_paths:       u64,
	max_path_entries: u64,
}

DEFAULT_TOPOLOGY_LIMITS :: Topology_Limits{
	max_vertices = 2_000_000_000,
	max_paths = 1_000_000_000,
	max_path_entries = 2_000_000_000,
}

Topology_Error :: enum u8 {
	None,
	Invalid_Input,
	Coordinate_Range,
	Vertex_Limit,
	Path_Limit,
	Path_Entry_Limit,
	Allocation_Failed,
	Arithmetic,
}

Endpoint_Occurrence :: struct {
	point:         Snapped_Point,
	segment_index: u32,
	segment_id:    contracts.Stable_ID,
	endpoint:      u8,
}

Topology_Local_Vertex :: struct {
	point:             Snapped_Point,
	occurrence_offset: u32,
	occurrence_count:  u32,
	global_index:      u32,
}

topology_reconstruct :: proc(
	schedule: Fixed_Layer_Schedule,
	segments: Snapped_Segment_Result,
	limits := DEFAULT_TOPOLOGY_LIMITS,
	allocator := context.allocator,
) -> (Topology_Result, Topology_Error) {
	layer_count := len(segments.layers)
	segment_count := len(segments.segments.segment_ids)
	if layer_count == 0 || len(schedule.layer_ids) != layer_count ||
	   !snapped_segment_soa_shape_valid(segments.segments, segment_count) ||
	   segment_count > max(int)/2 {
		return {}, .Invalid_Input
	}
	maximum_vertex_count := u64(segment_count)*2
	maximum_path_count := u64(segment_count)
	maximum_path_entries := u64(segment_count)*2
	if maximum_vertex_count > limits.max_vertices {
		return {}, .Vertex_Limit
	}
	if maximum_path_count > limits.max_paths {return {}, .Path_Limit}
	if maximum_path_entries > limits.max_path_entries {
		return {}, .Path_Entry_Limit
	}

	result: Topology_Result
	result.layers = make([]Topology_Layer, layer_count, allocator)
	result.vertices = make(
		[]Topology_Vertex,
		int(maximum_vertex_count),
		allocator,
	)
	result.paths = make(
		[]Topology_Path,
		int(maximum_path_count),
		allocator,
	)
	result.path_vertex_indices = make(
		[]u32,
		int(maximum_path_entries),
		allocator,
	)
	result.path_segment_indices = make(
		[]u32,
		segment_count,
		allocator,
	)
	occurrences := make(
		[]Endpoint_Occurrence,
		int(maximum_vertex_count),
		allocator,
	)
	local_vertices := make(
		[]Topology_Local_Vertex,
		int(maximum_vertex_count),
		allocator,
	)
	segment_vertex_a := make([]u32, segment_count, allocator)
	segment_vertex_b := make([]u32, segment_count, allocator)
	visited := make([]bool, segment_count, allocator)
	if result.layers == nil ||
	   (maximum_vertex_count > 0 &&
	    (result.vertices == nil || occurrences == nil ||
	     local_vertices == nil)) ||
	   (maximum_path_count > 0 && result.paths == nil) ||
	   (maximum_path_entries > 0 && result.path_vertex_indices == nil) ||
	   (segment_count > 0 &&
	    (result.path_segment_indices == nil ||
	     segment_vertex_a == nil || segment_vertex_b == nil ||
	     visited == nil)) {
		delete(occurrences, allocator)
		delete(local_vertices, allocator)
		delete(segment_vertex_a, allocator)
		delete(segment_vertex_b, allocator)
		delete(visited, allocator)
		topology_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(occurrences, allocator)
	defer delete(local_vertices, allocator)
	defer delete(segment_vertex_a, allocator)
	defer delete(segment_vertex_b, allocator)
	defer delete(visited, allocator)

	vertex_write := 0
	path_write := 0
	path_vertex_write := 0
	path_segment_write := 0
	expected_segment_offset: u64
	for layer, layer_index in segments.layers {
		if layer.offset != expected_segment_offset ||
		   u64(layer.count) > u64(segment_count)-expected_segment_offset {
			topology_result_destroy(&result, allocator)
			return {}, .Invalid_Input
		}
		expected_segment_offset += u64(layer.count)
		layer_vertex_start := vertex_write
		layer_path_start := path_write
		occurrence_count := int(layer.count)*2
		layer_occurrences := occurrences[:occurrence_count]
		for local_segment in 0..<int(layer.count) {
			segment_index := int(layer.offset)+local_segment
			if segments.segments.layer_indices[segment_index] !=
			   	u32(layer_index) ||
			   segments.segments.segment_ids[segment_index] ==
			   	contracts.INVALID_STABLE_ID ||
			   segments.segments.triangle_ids[segment_index] ==
			   	contracts.INVALID_STABLE_ID {
				topology_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			point_a := Snapped_Point{
				segments.segments.x0[segment_index],
				segments.segments.y0[segment_index],
			}
			point_b := Snapped_Point{
				segments.segments.x1[segment_index],
				segments.segments.y1[segment_index],
			}
			if point_a == point_b {
				topology_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			if geometry.point_2_validate({point_a.x, point_a.y}) != .None ||
			   geometry.point_2_validate({point_b.x, point_b.y}) != .None {
				topology_result_destroy(&result, allocator)
				return {}, .Coordinate_Range
			}
			layer_occurrences[local_segment*2] = {
				point = point_a,
				segment_index = u32(segment_index),
				segment_id = segments.segments.segment_ids[segment_index],
				endpoint = 0,
			}
			layer_occurrences[local_segment*2+1] = {
				point = point_b,
				segment_index = u32(segment_index),
				segment_id = segments.segments.segment_ids[segment_index],
				endpoint = 1,
			}
		}
		slice.sort_by(layer_occurrences, endpoint_occurrence_less)
		local_vertex_count := topology_cluster_endpoints(
			layer_occurrences,
			local_vertices,
			result.vertices,
			&vertex_write,
			segment_vertex_a,
			segment_vertex_b,
			u32(layer_index),
			schedule.layer_ids[layer_index],
			&result.non_manifold_vertex_count,
		)
		if local_vertex_count < 0 {
			topology_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
		layer_local_vertices := local_vertices[:local_vertex_count]
		layer_loop_count: u64
		layer_chain_count: u64
		for {
			start_vertex, start_ok := topology_find_start_vertex(
				layer_local_vertices,
				layer_occurrences,
				segment_vertex_a,
				segment_vertex_b,
				visited,
			)
			if !start_ok {break}
			if path_write >= len(result.paths) {
				topology_result_destroy(&result, allocator)
				return {}, .Path_Limit
			}
			path_vertex_start := path_vertex_write
			path_segment_start := path_segment_write
			current_vertex := start_vertex
			closed := false
			for traversal_count := 0;
			    traversal_count <= int(layer.count);
			    traversal_count += 1 {
				if path_vertex_write >= len(result.path_vertex_indices) {
					topology_result_destroy(&result, allocator)
					return {}, .Path_Entry_Limit
				}
				result.path_vertex_indices[path_vertex_write] =
					layer_local_vertices[current_vertex].global_index
				path_vertex_write += 1
				next_segment, next_vertex, next_ok :=
					topology_choose_next_edge(
						current_vertex,
						layer_local_vertices,
						layer_occurrences,
						segment_vertex_a,
						segment_vertex_b,
						segments.segments,
						visited,
					)
				if !next_ok {break}
				if path_segment_write >=
				   len(result.path_segment_indices) {
					topology_result_destroy(&result, allocator)
					return {}, .Path_Entry_Limit
				}
				visited[next_segment] = true
				result.path_segment_indices[path_segment_write] =
					u32(next_segment)
				path_segment_write += 1
				if next_vertex == start_vertex {
					closed = true
					break
				}
				current_vertex = next_vertex
			}
			path_vertex_count := path_vertex_write-path_vertex_start
			path_segment_count := path_segment_write-path_segment_start
			if path_segment_count == 0 {
				topology_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			path := Topology_Path{
				layer_index = u32(layer_index),
				vertex_offset = u64(path_vertex_start),
				vertex_count = u32(path_vertex_count),
				segment_offset = u64(path_segment_start),
				segment_count = u32(path_segment_count),
			}
			if closed {
				path.signed_area_2, path.winding =
					topology_path_area(
						result.vertices,
						result.path_vertex_indices[
							path_vertex_start:path_vertex_write
						],
					)
				if path.winding == .Zero {
					path.kind = .Degenerate_Loop
					path.id = contracts.stable_id_child(
						schedule.layer_ids[layer_index],
						.Loop,
						layer_loop_count,
					)
					result.degenerate_loop_count += 1
				} else {
					path.kind = .Loop
					path.id = contracts.stable_id_child(
						schedule.layer_ids[layer_index],
						.Loop,
						layer_loop_count,
					)
				}
				layer_loop_count += 1
			} else {
				path.kind = .Open_Chain
				path.id = contracts.stable_id_child(
					schedule.layer_ids[layer_index],
					.Chain,
					layer_chain_count,
				)
				layer_chain_count += 1
				result.open_chain_count += 1
			}
			result.paths[path_write] = path
			path_write += 1
		}
		result.layers[layer_index] = {
			vertex_offset = u64(layer_vertex_start),
			vertex_count = u32(vertex_write-layer_vertex_start),
			path_offset = u64(layer_path_start),
			path_count = u32(path_write-layer_path_start),
		}
	}
	if expected_segment_offset != u64(segment_count) ||
	   path_segment_write != segment_count {
		topology_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	result.vertices = result.vertices[:vertex_write]
	result.paths = result.paths[:path_write]
	result.path_vertex_indices =
		result.path_vertex_indices[:path_vertex_write]
	result.path_segment_indices =
		result.path_segment_indices[:path_segment_write]
	return result, .None
}

endpoint_occurrence_less :: proc(a, b: Endpoint_Occurrence) -> bool {
	if snapped_point_less(a.point, b.point) {return true}
	if snapped_point_less(b.point, a.point) {return false}
	if a.segment_id != b.segment_id {
		return u64(a.segment_id) < u64(b.segment_id)
	}
	return a.endpoint < b.endpoint
}

topology_cluster_endpoints :: proc(
	occurrences: []Endpoint_Occurrence,
	local_vertices: []Topology_Local_Vertex,
	output_vertices: []Topology_Vertex,
	output_vertex_write: ^int,
	segment_vertex_a, segment_vertex_b: []u32,
	layer_index: u32,
	layer_id: contracts.Stable_ID,
	non_manifold_count: ^u64,
) -> int {
	local_vertex_count := 0
	occurrence_index := 0
	for occurrence_index < len(occurrences) {
		end := occurrence_index+1
		for end < len(occurrences) &&
		    occurrences[end].point == occurrences[occurrence_index].point {
			end += 1
		}
		if local_vertex_count >= len(local_vertices) ||
		   output_vertex_write^ >= len(output_vertices) {
			return -1
		}
		global_index := output_vertex_write^
		degree := end-occurrence_index
		vertex_id := contracts.stable_id_child(
			layer_id,
			.Vertex,
			u64(local_vertex_count),
		)
		local_vertices[local_vertex_count] = {
			point = occurrences[occurrence_index].point,
			occurrence_offset = u32(occurrence_index),
			occurrence_count = u32(degree),
			global_index = u32(global_index),
		}
		output_vertices[global_index] = {
			id = vertex_id,
			layer_index = layer_index,
			point = occurrences[occurrence_index].point,
			degree = u32(degree),
		}
		if degree > 2 {non_manifold_count^ += 1}
		for occurrence in occurrences[occurrence_index:end] {
			if occurrence.endpoint == 0 {
				segment_vertex_a[occurrence.segment_index] =
					u32(local_vertex_count)
			} else {
				segment_vertex_b[occurrence.segment_index] =
					u32(local_vertex_count)
			}
		}
		local_vertex_count += 1
		output_vertex_write^ += 1
		occurrence_index = end
	}
	return local_vertex_count
}

topology_find_start_vertex :: proc(
	vertices: []Topology_Local_Vertex,
	occurrences: []Endpoint_Occurrence,
	segment_vertex_a, segment_vertex_b: []u32,
	visited: []bool,
) -> (u32, bool) {
	for pass_index in 0..<2 {
		degree_one_only := pass_index == 0
		for vertex, vertex_index in vertices {
			if degree_one_only && vertex.occurrence_count != 1 {continue}
			if topology_vertex_has_unvisited_edge(
				vertex,
				occurrences,
				segment_vertex_a,
				segment_vertex_b,
				visited,
			) {
				return u32(vertex_index), true
			}
		}
	}
	return 0, false
}

topology_vertex_has_unvisited_edge :: proc(
	vertex: Topology_Local_Vertex,
	occurrences: []Endpoint_Occurrence,
	segment_vertex_a, segment_vertex_b: []u32,
	visited: []bool,
) -> bool {
	start := int(vertex.occurrence_offset)
	end := start+int(vertex.occurrence_count)
	for occurrence in occurrences[start:end] {
		segment_index := int(occurrence.segment_index)
		if !visited[segment_index] &&
		   segment_vertex_a[segment_index] !=
		   	segment_vertex_b[segment_index] {
			return true
		}
	}
	return false
}

topology_choose_next_edge :: proc(
	current_vertex: u32,
	vertices: []Topology_Local_Vertex,
	occurrences: []Endpoint_Occurrence,
	segment_vertex_a, segment_vertex_b: []u32,
	segments: Snapped_Segment_SoA,
	visited: []bool,
) -> (segment_index: int, next_vertex: u32, ok: bool) {
	vertex := vertices[current_vertex]
	start := int(vertex.occurrence_offset)
	end := start+int(vertex.occurrence_count)
	for occurrence in occurrences[start:end] {
		candidate_segment := int(occurrence.segment_index)
		if visited[candidate_segment] {continue}
		candidate_vertex := segment_vertex_a[candidate_segment]
		if candidate_vertex == current_vertex {
			candidate_vertex = segment_vertex_b[candidate_segment]
		}
		if candidate_vertex == current_vertex {continue}
		if !ok ||
		   snapped_point_less(
		   	vertices[candidate_vertex].point,
		   	vertices[next_vertex].point,
		   ) ||
		   (vertices[candidate_vertex].point ==
		    vertices[next_vertex].point &&
		    u64(segments.segment_ids[candidate_segment]) <
		    u64(segments.segment_ids[segment_index])) {
			segment_index = candidate_segment
			next_vertex = candidate_vertex
			ok = true
		}
	}
	return
}

topology_path_area :: proc(
	vertices: []Topology_Vertex,
	path_vertex_indices: []u32,
) -> (i128, geometry.Predicate_Sign) {
	area: i128
	for vertex_index in 0..<len(path_vertex_indices) {
		next_index := (vertex_index+1)%len(path_vertex_indices)
		a := vertices[path_vertex_indices[vertex_index]].point
		b := vertices[path_vertex_indices[next_index]].point
		area += i128(i64(a.x))*i128(i64(b.y))-
			i128(i64(a.y))*i128(i64(b.x))
	}
	switch {
	case area < 0: return area, .Negative
	case area > 0: return area, .Positive
	case:         return 0, .Zero
	}
}

topology_result_destroy :: proc(
	result: ^Topology_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.vertices, allocator)
	delete(result.paths, allocator)
	delete(result.path_vertex_indices, allocator)
	delete(result.path_segment_indices, allocator)
	result^ = {}
}
