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

// Joins the snapped segments of every layer into loops and open chains. Layers are reconstructed
// independently on the worker threads, each inside its own region of the output arrays (sized for
// the most a layer can produce), and then compacted in layer order. The result does not depend on
// the thread count, and errors are reported for the first failing layer, as a serial pass would.
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
	outcomes := make([]Topology_Layer_Outcome, layer_count, allocator)
	if result.layers == nil || outcomes == nil ||
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
		delete(outcomes, allocator)
		topology_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(occurrences, allocator)
	defer delete(local_vertices, allocator)
	defer delete(segment_vertex_a, allocator)
	defer delete(segment_vertex_b, allocator)
	defer delete(visited, allocator)
	defer delete(outcomes, allocator)

	// The layers must tile the segment array in order; `tiled` layers do.
	tiled := layer_count
	expected_segment_offset: u64
	for layer, layer_index in segments.layers {
		if layer.offset != expected_segment_offset ||
		   u64(layer.count) > u64(segment_count)-expected_segment_offset {
			tiled = layer_index
			break
		}
		expected_segment_offset += u64(layer.count)
	}

	ctx := Topology_Reconstruct_Context{
		schedule         = schedule,
		segments         = segments,
		result           = &result,
		occurrences      = occurrences,
		local_vertices   = local_vertices,
		segment_vertex_a = segment_vertex_a,
		segment_vertex_b = segment_vertex_b,
		visited          = visited,
		outcomes         = outcomes,
	}
	slicing_parallel_for(tiled, &ctx, topology_reconstruct_layer)

	for outcome in outcomes[:tiled] {
		if outcome.error != .None {
			topology_result_destroy(&result, allocator)
			return {}, outcome.error
		}
	}
	if tiled < layer_count {
		topology_result_destroy(&result, allocator)
		return {}, .Invalid_Input
	}
	total_path_segments := 0
	for outcome in outcomes {total_path_segments += outcome.path_segment_count}
	if expected_segment_offset != u64(segment_count) ||
	   total_path_segments != segment_count {
		topology_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}

	// Compact the layer regions in order. Each compacted start is at or before its region start,
	// so copying forward layer by layer never overwrites data that is still to be moved.
	vertex_write := 0
	path_write := 0
	path_vertex_write := 0
	path_segment_write := 0
	for layer, layer_index in segments.layers {
		outcome := outcomes[layer_index]
		region := int(layer.offset)
		copy(result.vertices[vertex_write:], result.vertices[2*region:2*region+outcome.vertex_count])
		copy(result.path_vertex_indices[path_vertex_write:], result.path_vertex_indices[2*region:2*region+outcome.path_vertex_count])
		for &index in result.path_vertex_indices[path_vertex_write:path_vertex_write+outcome.path_vertex_count] {
			index += u32(vertex_write)
		}
		copy(result.path_segment_indices[path_segment_write:], result.path_segment_indices[region:region+outcome.path_segment_count])
		copy(result.paths[path_write:], result.paths[region:region+outcome.path_count])
		for &path in result.paths[path_write:path_write+outcome.path_count] {
			path.vertex_offset += u64(path_vertex_write)
			path.segment_offset += u64(path_segment_write)
		}
		result.layers[layer_index] = {
			vertex_offset = u64(vertex_write),
			vertex_count = u32(outcome.vertex_count),
			path_offset = u64(path_write),
			path_count = u32(outcome.path_count),
		}
		result.open_chain_count += outcome.open_chain_count
		result.degenerate_loop_count += outcome.degenerate_loop_count
		result.non_manifold_vertex_count += outcome.non_manifold_vertex_count
		vertex_write += outcome.vertex_count
		path_write += outcome.path_count
		path_vertex_write += outcome.path_vertex_count
		path_segment_write += outcome.path_segment_count
	}
	result.vertices = result.vertices[:vertex_write]
	result.paths = result.paths[:path_write]
	result.path_vertex_indices =
		result.path_vertex_indices[:path_vertex_write]
	result.path_segment_indices =
		result.path_segment_indices[:path_segment_write]
	return result, .None
}

// What one layer produced in its regions, and the first error it met.
@(private = "file")
Topology_Layer_Outcome :: struct {
	error:                     Topology_Error,
	vertex_count:              int,
	path_count:                int,
	path_vertex_count:         int,
	path_segment_count:        int,
	open_chain_count:          u64,
	degenerate_loop_count:     u64,
	non_manifold_vertex_count: u64,
}

@(private = "file")
Topology_Reconstruct_Context :: struct {
	schedule:         Fixed_Layer_Schedule,
	segments:         Snapped_Segment_Result,
	result:           ^Topology_Result,
	occurrences:      []Endpoint_Occurrence,
	local_vertices:   []Topology_Local_Vertex,
	segment_vertex_a: []u32,
	segment_vertex_b: []u32,
	visited:          []bool,
	outcomes:         []Topology_Layer_Outcome,
}

// Reconstructs one layer. A layer with segments [offset, offset+count) owns entries
// [2*offset, 2*(offset+count)) of the occurrence, local vertex, vertex and path vertex arrays and
// [offset, offset+count) of the path and path segment arrays. Vertex indices and path offsets it
// writes are relative to its regions until the compaction pass.
@(private = "file")
topology_reconstruct_layer :: proc(c: ^Topology_Reconstruct_Context, layer_index: int) {
	layer := c.segments.layers[layer_index]
	segments := c.segments.segments
	outcome := &c.outcomes[layer_index]
	offset := int(layer.offset)
	count := int(layer.count)
	layer_occurrences := c.occurrences[2*offset:2*offset+2*count]
	region_local_vertices := c.local_vertices[2*offset:2*offset+2*count]
	region_vertices := c.result.vertices[2*offset:2*offset+2*count]
	region_paths := c.result.paths[offset:offset+count]
	region_path_vertices := c.result.path_vertex_indices[2*offset:2*offset+2*count]
	region_path_segments := c.result.path_segment_indices[offset:offset+count]

	for local_segment in 0..<count {
		segment_index := offset+local_segment
		if segments.layer_indices[segment_index] != u32(layer_index) ||
		   segments.segment_ids[segment_index] == contracts.INVALID_STABLE_ID ||
		   segments.triangle_ids[segment_index] == contracts.INVALID_STABLE_ID {
			outcome.error = .Invalid_Input
			return
		}
		point_a := Snapped_Point{segments.x0[segment_index], segments.y0[segment_index]}
		point_b := Snapped_Point{segments.x1[segment_index], segments.y1[segment_index]}
		if point_a == point_b {
			outcome.error = .Invalid_Input
			return
		}
		if geometry.point_2_validate({point_a.x, point_a.y}) != .None ||
		   geometry.point_2_validate({point_b.x, point_b.y}) != .None {
			outcome.error = .Coordinate_Range
			return
		}
		layer_occurrences[local_segment*2] = {
			point = point_a,
			segment_index = u32(segment_index),
			segment_id = segments.segment_ids[segment_index],
			endpoint = 0,
		}
		layer_occurrences[local_segment*2+1] = {
			point = point_b,
			segment_index = u32(segment_index),
			segment_id = segments.segment_ids[segment_index],
			endpoint = 1,
		}
	}
	slice.sort_by(layer_occurrences, endpoint_occurrence_less)
	vertex_write := 0
	local_vertex_count := topology_cluster_endpoints(
		layer_occurrences,
		region_local_vertices,
		region_vertices,
		&vertex_write,
		c.segment_vertex_a,
		c.segment_vertex_b,
		u32(layer_index),
		c.schedule.layer_ids[layer_index],
		&outcome.non_manifold_vertex_count,
	)
	if local_vertex_count < 0 {
		outcome.error = .Arithmetic
		return
	}
	outcome.vertex_count = vertex_write
	layer_local_vertices := region_local_vertices[:local_vertex_count]
	path_write := 0
	path_vertex_write := 0
	path_segment_write := 0
	layer_loop_count: u64
	layer_chain_count: u64
	search: Topology_Start_Search
	for {
		start_vertex, start_ok := topology_find_start_vertex(
			layer_local_vertices,
			layer_occurrences,
			c.segment_vertex_a,
			c.segment_vertex_b,
			c.visited,
			&search,
		)
		if !start_ok {break}
		if path_write >= len(region_paths) {
			outcome.error = .Path_Limit
			return
		}
		path_vertex_start := path_vertex_write
		path_segment_start := path_segment_write
		current_vertex := start_vertex
		closed := false
		for traversal_count := 0; traversal_count <= count; traversal_count += 1 {
			if path_vertex_write >= len(region_path_vertices) {
				outcome.error = .Path_Entry_Limit
				return
			}
			region_path_vertices[path_vertex_write] = layer_local_vertices[current_vertex].global_index
			path_vertex_write += 1
			next_segment, next_vertex, next_ok := topology_choose_next_edge(
				current_vertex,
				layer_local_vertices,
				layer_occurrences,
				c.segment_vertex_a,
				c.segment_vertex_b,
				segments,
				c.visited,
			)
			if !next_ok {break}
			if path_segment_write >= len(region_path_segments) {
				outcome.error = .Path_Entry_Limit
				return
			}
			c.visited[next_segment] = true
			region_path_segments[path_segment_write] = u32(next_segment)
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
			outcome.error = .Arithmetic
			return
		}
		path := Topology_Path{
			layer_index = u32(layer_index),
			vertex_offset = u64(path_vertex_start),
			vertex_count = u32(path_vertex_count),
			segment_offset = u64(path_segment_start),
			segment_count = u32(path_segment_count),
		}
		if closed {
			path.signed_area_2, path.winding = topology_path_area(
				region_vertices,
				region_path_vertices[path_vertex_start:path_vertex_write],
			)
			if path.winding == .Zero {
				path.kind = .Degenerate_Loop
				outcome.degenerate_loop_count += 1
			} else {
				path.kind = .Loop
			}
			path.id = contracts.stable_id_child(c.schedule.layer_ids[layer_index], .Loop, layer_loop_count)
			layer_loop_count += 1
		} else {
			path.kind = .Open_Chain
			path.id = contracts.stable_id_child(c.schedule.layer_ids[layer_index], .Chain, layer_chain_count)
			layer_chain_count += 1
			outcome.open_chain_count += 1
		}
		region_paths[path_write] = path
		path_write += 1
	}
	outcome.path_count = path_write
	outcome.path_vertex_count = path_vertex_write
	outcome.path_segment_count = path_segment_write
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

// Where the two passes of topology_find_start_vertex resume. A vertex without an unvisited edge
// never gains one, because `visited` only grows, so each pass can skip the vertices it has passed.
Topology_Start_Search :: struct {
	cursors: [2]int,
}

// The first vertex with an unvisited edge, preferring vertices of degree one (chain ends).
topology_find_start_vertex :: proc(
	vertices: []Topology_Local_Vertex,
	occurrences: []Endpoint_Occurrence,
	segment_vertex_a, segment_vertex_b: []u32,
	visited: []bool,
	search: ^Topology_Start_Search,
) -> (u32, bool) {
	for pass_index in 0..<2 {
		degree_one_only := pass_index == 0
		for search.cursors[pass_index] < len(vertices) {
			vertex_index := search.cursors[pass_index]
			vertex := vertices[vertex_index]
			if !(degree_one_only && vertex.occurrence_count != 1) &&
			   topology_vertex_has_unvisited_edge(
			   	vertex,
			   	occurrences,
			   	segment_vertex_a,
			   	segment_vertex_b,
			   	visited,
			   ) {
				return u32(vertex_index), true
			}
			search.cursors[pass_index] += 1
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
