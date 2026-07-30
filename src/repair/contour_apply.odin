package repair

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import slicing "../slicing"

contour_repair_apply_for_regions :: proc(
	topology: slicing.Topology_Result,
	repair: Contour_Repair_Result,
	allocator := context.allocator,
) -> (slicing.Topology_Result, Contour_Repair_Error) {
	if !slicing.regions_topology_shape_valid(topology) ||
	   !contour_repair_topology_storage_valid(topology) ||
	   u64(repair.source_path_index) >= u64(len(topology.paths)) ||
	   repair.source_path_id == contracts.INVALID_STABLE_ID ||
	   topology.paths[repair.source_path_index].id !=
	   	repair.source_path_id ||
	   topology.paths[repair.source_path_index].layer_index !=
	   	repair.layer_index ||
	   len(repair.output.paths) == 0 ||
	   len(repair.edges) != len(repair.output.points) {
		return {}, .Invalid_Input
	}
	_, output_hash_ok := polygon.polygon_set_hash(repair.output)
	if !output_hash_ok {return {}, .Invalid_Input}
	source_path := topology.paths[repair.source_path_index]
	output_path_count := u64(len(repair.output.paths))
	output_point_count := u64(len(repair.output.points))
	source_layer := topology.layers[repair.layer_index]
	if u64(source_layer.path_count)-1+output_path_count > u64(max(u32)) {
		return {}, .Arithmetic
	}
	retained_degrees := make([]u32, len(topology.vertices), allocator)
	vertex_map := make([]u32, len(topology.vertices), allocator)
	retained_layer_counts := make([]u64, len(topology.layers), allocator)
	if retained_degrees == nil || vertex_map == nil ||
	   retained_layer_counts == nil {
		delete(retained_degrees, allocator)
		delete(vertex_map, allocator)
		delete(retained_layer_counts, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(retained_degrees, allocator)
	defer delete(vertex_map, allocator)
	defer delete(retained_layer_counts, allocator)
	for &mapped_index in vertex_map {mapped_index = max(u32)}
	for path, path_index in topology.paths {
		if u32(path_index) == repair.source_path_index {continue}
		switch path.kind {
		case .Loop, .Degenerate_Loop:
			if path.vertex_count != path.segment_count {
				return {}, .Invalid_Input
			}
		case .Open_Chain:
			if path.vertex_count != path.segment_count+1 {
				return {}, .Invalid_Input
			}
		case .Invalid:
			return {}, .Invalid_Input
		}
		start := int(path.vertex_offset)
		end := start+int(path.vertex_count)
		vertices := topology.path_vertex_indices[start:end]
		for local_segment in 0..<int(path.segment_count) {
			next_vertex := local_segment+1
			if path.kind != .Open_Chain &&
			   next_vertex == len(vertices) {
				next_vertex = 0
			}
			vertex_a := vertices[local_segment]
			vertex_b := vertices[next_vertex]
			if u64(vertex_a) >= u64(len(topology.vertices)) ||
			   u64(vertex_b) >= u64(len(topology.vertices)) ||
			   vertex_a == vertex_b ||
			   retained_degrees[vertex_a] == max(u32) ||
			   retained_degrees[vertex_b] == max(u32) {
				return {}, .Arithmetic
			}
			retained_degrees[vertex_a] += 1
			retained_degrees[vertex_b] += 1
		}
	}
	retained_vertex_count: u64
	for layer, layer_index in topology.layers {
		start := int(layer.vertex_offset)
		end := start+int(layer.vertex_count)
		for source_vertex_index in start..<end {
			if retained_degrees[source_vertex_index] == 0 {continue}
			if topology.vertices[source_vertex_index].layer_index !=
			   u32(layer_index) {
				return {}, .Invalid_Input
			}
			retained_layer_counts[layer_index] += 1
			retained_vertex_count += 1
		}
	}
	if retained_layer_counts[repair.layer_index]+
	   output_point_count > u64(max(u32)) {
		return {}, .Arithmetic
	}
	path_count := u64(len(topology.paths))-1+output_path_count
	if retained_vertex_count > max(u64)-output_point_count {
		return {}, .Arithmetic
	}
	vertex_count := retained_vertex_count+output_point_count
	path_vertex_count :=
		u64(len(topology.path_vertex_indices))-
		u64(source_path.vertex_count)+output_point_count
	path_segment_count :=
		u64(len(topology.path_segment_indices))-
		u64(source_path.segment_count)+output_point_count
	if path_count > u64(max(int)) ||
	   vertex_count > u64(max(int)) ||
	   vertex_count > u64(max(u32))+1 ||
	   path_vertex_count > u64(max(int)) ||
	   path_segment_count > u64(max(int)) {
		return {}, .Arithmetic
	}

	result: slicing.Topology_Result
	result.layers = make([]slicing.Topology_Layer, len(topology.layers), allocator)
	result.vertices = make(
		[]slicing.Topology_Vertex,
		int(vertex_count),
		allocator,
	)
	result.paths = make(
		[]slicing.Topology_Path,
		int(path_count),
		allocator,
	)
	result.path_vertex_indices = make(
		[]u32,
		int(path_vertex_count),
		allocator,
	)
	result.path_segment_indices = make(
		[]u32,
		int(path_segment_count),
		allocator,
	)
	if result.layers == nil || result.vertices == nil ||
	   result.paths == nil || result.path_vertex_indices == nil ||
	   result.path_segment_indices == nil {
		slicing.topology_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	vertex_write := 0
	repair_vertex_offset := 0
	for source_layer, layer_index in topology.layers {
		layer_vertex_start := vertex_write
		source_vertex_start := int(source_layer.vertex_offset)
		source_vertex_end :=
			source_vertex_start+int(source_layer.vertex_count)
		for source_vertex, source_vertex_index in
		    topology.vertices[source_vertex_start:source_vertex_end] {
			global_source_vertex_index :=
				source_vertex_start+source_vertex_index
			degree := retained_degrees[global_source_vertex_index]
			if degree == 0 {continue}
			if source_vertex.layer_index != u32(layer_index) ||
			   vertex_write > int(max(u32)) {
				slicing.topology_result_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			output_vertex := source_vertex
			output_vertex.degree = degree
			vertex_map[global_source_vertex_index] = u32(vertex_write)
			result.vertices[vertex_write] = output_vertex
			if degree > 2 {
				result.non_manifold_vertex_count += 1
			}
			vertex_write += 1
		}
		if u32(layer_index) == repair.layer_index {
			repair_vertex_offset = vertex_write
			for output_path, output_path_index in repair.output.paths {
				path_id := contracts.stable_id_child(
					repair.source_path_id,
					.Loop,
					u64(output_path_index),
				)
				start := int(output_path.offset)
				end := start+int(output_path.count)
				for point, local_index in
				    repair.output.points[start:end] {
					result.vertices[vertex_write] = {
						id = contracts.stable_id_child(
							path_id,
							.Vertex,
							u64(local_index),
						),
						layer_index = repair.layer_index,
						point = {point.x, point.y},
						degree = 2,
					}
					vertex_write += 1
				}
			}
		}
		result.layers[layer_index].vertex_offset =
			u64(layer_vertex_start)
			result.layers[layer_index].vertex_count =
				u32(vertex_write-layer_vertex_start)
		if u64(result.layers[layer_index].vertex_count) !=
		   retained_layer_counts[layer_index]+
		   	(u64(output_point_count) if
		   	 u32(layer_index) == repair.layer_index else 0) {
			slicing.topology_result_destroy(&result, allocator)
			return {}, .Arithmetic
		}
	}
	if vertex_write != len(result.vertices) {
		slicing.topology_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}

	path_write := 0
	vertex_entry_write := 0
	segment_entry_write := 0
	repair_edge_write := 0
	for source_layer, layer_index in topology.layers {
		layer_path_start := path_write
		source_path_start := int(source_layer.path_offset)
		source_path_end := source_path_start+int(source_layer.path_count)
		for source_path_index in source_path_start..<source_path_end {
			if u32(source_path_index) != repair.source_path_index {
				path := topology.paths[source_path_index]
				path.vertex_offset = u64(vertex_entry_write)
				path.segment_offset = u64(segment_entry_write)
				source_vertex_entry_start :=
					int(topology.paths[source_path_index].vertex_offset)
				source_vertex_entry_end :=
					source_vertex_entry_start+
					int(path.vertex_count)
				for source_vertex_index in topology.path_vertex_indices[
				    source_vertex_entry_start:source_vertex_entry_end] {
					if u64(source_vertex_index) >=
					   	u64(len(vertex_map)) ||
					   vertex_map[source_vertex_index] == max(u32) {
						slicing.topology_result_destroy(
							&result,
							allocator,
						)
						return {}, .Invalid_Input
					}
					result.path_vertex_indices[vertex_entry_write] =
						vertex_map[source_vertex_index]
					vertex_entry_write += 1
				}
				source_segment_start :=
					int(topology.paths[source_path_index].segment_offset)
				source_segment_end :=
					source_segment_start+int(path.segment_count)
				copy(
					result.path_segment_indices[
						segment_entry_write:
						segment_entry_write+int(path.segment_count)
					],
					topology.path_segment_indices[
						source_segment_start:source_segment_end
					],
				)
				segment_entry_write += int(path.segment_count)
				result.paths[path_write] = path
				if path.kind == .Open_Chain {
					result.open_chain_count += 1
				} else if path.kind == .Degenerate_Loop {
					result.degenerate_loop_count += 1
				}
				path_write += 1
				continue
			}

			for output_path, output_path_index in repair.output.paths {
				path_id := contracts.stable_id_child(
					repair.source_path_id,
					.Loop,
					u64(output_path_index),
				)
				point_start := int(output_path.offset)
				point_end := point_start+int(output_path.count)
				area := polygon.polygon_path_area_2(
					repair.output.points[point_start:point_end],
				)
				winding := geometry.Predicate_Sign.Positive
				if area < 0 {winding = .Negative}
				result.paths[path_write] = {
					id = path_id,
					layer_index = repair.layer_index,
					kind = .Loop,
					vertex_offset = u64(vertex_entry_write),
					vertex_count = u32(output_path.count),
					segment_offset = u64(segment_entry_write),
					segment_count = u32(output_path.count),
					signed_area_2 = area,
					winding = winding,
				}
				for local_index in 0..<int(output_path.count) {
					result.path_vertex_indices[vertex_entry_write] =
						u32(
							repair_vertex_offset+
							point_start+local_index,
						)
					vertex_entry_write += 1
					if repair_edge_write >= len(repair.edges) {
						slicing.topology_result_destroy(
							&result,
							allocator,
						)
						return {}, .Invalid_Input
					}
					edge := repair.edges[repair_edge_write]
					if edge.output_path_index !=
					   	u32(output_path_index) ||
					   edge.output_edge_index != u32(local_index) ||
					   edge.source_count == 0 ||
					   edge.source_offset >=
					   	u64(len(repair.sources)) {
						slicing.topology_result_destroy(
							&result,
							allocator,
						)
						return {}, .Invalid_Input
					}
					result.path_segment_indices[segment_entry_write] =
						repair.sources[
							edge.source_offset
						].segment_index
					segment_entry_write += 1
					repair_edge_write += 1
				}
				path_write += 1
			}
		}
		result.layers[layer_index].path_offset = u64(layer_path_start)
		result.layers[layer_index].path_count =
			u32(path_write-layer_path_start)
	}
	if path_write != len(result.paths) ||
	   vertex_entry_write != len(result.path_vertex_indices) ||
	   segment_entry_write != len(result.path_segment_indices) ||
	   repair_edge_write != len(repair.edges) {
		slicing.topology_result_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

contour_repair_topology_storage_valid :: proc(
	topology: slicing.Topology_Result,
) -> bool {
	expected_vertex_offset: u64
	expected_segment_offset: u64
	for layer in topology.layers {
		if layer.vertex_offset != expected_vertex_offset ||
		   expected_vertex_offset > u64(len(topology.vertices)) ||
		   u64(layer.vertex_count) >
		   	u64(len(topology.vertices))-expected_vertex_offset {
			return false
		}
		path_start := int(layer.path_offset)
		path_end := path_start+int(layer.path_count)
		for path in topology.paths[path_start:path_end] {
			if path.segment_offset != expected_segment_offset ||
			   expected_segment_offset >
			   	u64(len(topology.path_segment_indices)) ||
			   u64(path.segment_count) >
			   	u64(len(topology.path_segment_indices))-
			    	expected_segment_offset {
				return false
			}
			vertex_start := int(path.vertex_offset)
			vertex_end := vertex_start+int(path.vertex_count)
			for vertex_index in
			    topology.path_vertex_indices[vertex_start:vertex_end] {
				if u64(vertex_index) < layer.vertex_offset ||
				   u64(vertex_index) >=
				   	layer.vertex_offset+u64(layer.vertex_count) {
					return false
				}
			}
			expected_segment_offset += u64(path.segment_count)
		}
		expected_vertex_offset += u64(layer.vertex_count)
	}
	return expected_vertex_offset == u64(len(topology.vertices)) &&
		expected_segment_offset ==
			u64(len(topology.path_segment_indices))
}
