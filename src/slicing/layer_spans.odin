package slicing

import contracts "../contracts"
import geometry "../geometry"

Triangle_Span_Kind :: enum u8 {
	None,
	Crossing_Candidates,
	Quantized_Planar,
}

Triangle_Layer_Range :: struct {
	first_layer: u32,
	layer_count: u32,
	kind:        Triangle_Span_Kind,
}

Layer_Descriptor :: struct {
	offset: u64,
	count:  u32,
}

Layer_Span_Index :: struct {
	triangle_ranges: []Triangle_Layer_Range,
	layers:          []Layer_Descriptor,
	triangle_indices: []u32,
	triangle_ids:    []contracts.Stable_ID,
}

Layer_Span_Limits :: struct {
	max_pairs: u64,
}

DEFAULT_LAYER_SPAN_LIMITS :: Layer_Span_Limits{
	max_pairs = 1_000_000_000,
}

Layer_Span_Error :: enum u8 {
	None,
	Invalid_Mesh,
	Invalid_Schedule,
	Coordinate_Range,
	Pair_Limit,
	Allocation_Failed,
}

layer_span_index_build :: proc(
	mesh: geometry.Canonical_Mesh,
	schedule: Fixed_Layer_Schedule,
	limits := DEFAULT_LAYER_SPAN_LIMITS,
	allocator := context.allocator,
) -> (Layer_Span_Index, Layer_Span_Error) {
	triangle_count := len(mesh.triangle_ids)
	vertex_count := len(mesh.vertex_z)
	layer_count := len(schedule.layer_z)
	if triangle_count == 0 || vertex_count == 0 ||
	   len(mesh.triangle_a) != triangle_count ||
	   len(mesh.triangle_b) != triangle_count ||
	   len(mesh.triangle_c) != triangle_count {
		return {}, .Invalid_Mesh
	}
	if layer_count == 0 || len(schedule.layer_ids) != layer_count {
		return {}, .Invalid_Schedule
	}
	for layer_index in 1..<layer_count {
		if schedule.layer_z[layer_index] <= schedule.layer_z[layer_index-1] {
			return {}, .Invalid_Schedule
		}
	}

	index: Layer_Span_Index
	index.triangle_ranges = make(
		[]Triangle_Layer_Range,
		triangle_count,
		allocator,
	)
	index.layers = make([]Layer_Descriptor, layer_count, allocator)
	layer_counts := make([]u64, layer_count, allocator)
	if index.triangle_ranges == nil || index.layers == nil ||
	   layer_counts == nil {
		delete(layer_counts, allocator)
		layer_span_index_destroy(&index, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(layer_counts, allocator)

	pair_count: u64
	for triangle_index in 0..<triangle_count {
		a := mesh.triangle_a[triangle_index]
		b := mesh.triangle_b[triangle_index]
		c := mesh.triangle_c[triangle_index]
		if u64(a) >= u64(vertex_count) ||
		   u64(b) >= u64(vertex_count) ||
		   u64(c) >= u64(vertex_count) {
			layer_span_index_destroy(&index, allocator)
			return {}, .Invalid_Mesh
		}
		z0 := mesh.vertex_z[a]
		z1 := mesh.vertex_z[b]
		z2 := mesh.vertex_z[c]
		minimum_z := min(z0, min(z1, z2))
		maximum_z := max(z0, max(z1, z2))
		minimum_key, minimum_error :=
			geometry.millimetres_to_micrometres_quantized(
				contracts.Millimetres(minimum_z),
				.Floor,
			)
		maximum_key, maximum_error :=
			geometry.millimetres_to_micrometres_quantized(
				contracts.Millimetres(maximum_z),
				.Ceil,
			)
		z0_key, z0_error := geometry.millimetres_to_micrometres(
			contracts.Millimetres(z0),
		)
		z1_key, z1_error := geometry.millimetres_to_micrometres(
			contracts.Millimetres(z1),
		)
		z2_key, z2_error := geometry.millimetres_to_micrometres(
			contracts.Millimetres(z2),
		)
		if minimum_error != .None || maximum_error != .None ||
		   z0_error != .None || z1_error != .None || z2_error != .None {
			layer_span_index_destroy(&index, allocator)
			return {}, .Coordinate_Range
		}

		range_value: Triangle_Layer_Range
		if z0_key == z1_key && z1_key == z2_key {
			layer_index := layer_lower_bound(schedule.layer_z, z0_key)
			if layer_index < layer_count &&
			   schedule.layer_z[layer_index] == z0_key {
				range_value = {
					first_layer = u32(layer_index),
					layer_count = 1,
					kind = .Quantized_Planar,
				}
			}
		} else {
			first_layer := layer_lower_bound(schedule.layer_z, minimum_key)
			end_layer := layer_lower_bound(schedule.layer_z, maximum_key)
			if end_layer > first_layer {
				range_value = {
					first_layer = u32(first_layer),
					layer_count = u32(end_layer-first_layer),
					kind = .Crossing_Candidates,
				}
			}
		}
		index.triangle_ranges[triangle_index] = range_value
		added_pair_count := u64(range_value.layer_count)
		if pair_count > limits.max_pairs ||
		   added_pair_count > limits.max_pairs-pair_count {
			layer_span_index_destroy(&index, allocator)
			return {}, .Pair_Limit
		}
		pair_count += added_pair_count
		for local_layer in 0..<int(range_value.layer_count) {
			layer_index := int(range_value.first_layer)+local_layer
			layer_counts[layer_index] += 1
		}
	}
	if pair_count > u64(max(int)) {
		layer_span_index_destroy(&index, allocator)
		return {}, .Pair_Limit
	}

	offset: u64
	for layer_index in 0..<layer_count {
		if layer_counts[layer_index] > u64(max(u32)) {
			layer_span_index_destroy(&index, allocator)
			return {}, .Pair_Limit
		}
		index.layers[layer_index] = {
			offset = offset,
			count = u32(layer_counts[layer_index]),
		}
		offset += layer_counts[layer_index]
	}
	index.triangle_ids = make(
		[]contracts.Stable_ID,
		int(pair_count),
		allocator,
	)
	index.triangle_indices = make([]u32, int(pair_count), allocator)
	if pair_count > 0 &&
	   (index.triangle_ids == nil || index.triangle_indices == nil) {
		layer_span_index_destroy(&index, allocator)
		return {}, .Allocation_Failed
	}
	cursors := make([]u64, layer_count, allocator)
	if cursors == nil {
		layer_span_index_destroy(&index, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(cursors, allocator)
	for layer_index in 0..<layer_count {
		cursors[layer_index] = index.layers[layer_index].offset
	}
	for triangle_index in 0..<triangle_count {
		range_value := index.triangle_ranges[triangle_index]
		for local_layer in 0..<int(range_value.layer_count) {
			layer_index := int(range_value.first_layer)+local_layer
			write_index := cursors[layer_index]
			index.triangle_indices[write_index] = u32(triangle_index)
			index.triangle_ids[write_index] = mesh.triangle_ids[triangle_index]
			cursors[layer_index] += 1
		}
	}
	return index, .None
}

layer_span_index_destroy :: proc(
	index: ^Layer_Span_Index,
	allocator := context.allocator,
) {
	delete(index.triangle_ranges, allocator)
	delete(index.layers, allocator)
	delete(index.triangle_indices, allocator)
	delete(index.triangle_ids, allocator)
	index^ = {}
}

layer_lower_bound :: proc(
	layers: []contracts.Micrometres,
	value: contracts.Micrometres,
) -> int {
	left := 0
	right := len(layers)
	for left < right {
		middle := left+(right-left)/2
		if layers[middle] < value {
			left = middle+1
		} else {
			right = middle
		}
	}
	return left
}
