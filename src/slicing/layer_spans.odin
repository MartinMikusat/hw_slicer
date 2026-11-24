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
	if index.triangle_ranges == nil || index.layers == nil {
		layer_span_index_destroy(&index, allocator)
		return {}, .Allocation_Failed
	}
	chunk_count := 1
	worker_threads := slicing_worker_threads()
	if worker_threads > 1 && triangle_count >= 4096 {
		chunk_count = min(worker_threads*2, (triangle_count+1023)/1024)
		// Keep the chunk × layer histogram bounded (at most ~2M u64 entries = 16 MiB).
		if layer_count > 0 && u64(chunk_count)*u64(layer_count) > 2_000_000 {
			chunk_count = max(1, int(2_000_000/u64(layer_count)))
		}
	}

	if chunk_count == 1 {
		layer_counts := make([]u64, layer_count, allocator)
		if layer_counts == nil {
			layer_span_index_destroy(&index, allocator)
			return {}, .Allocation_Failed
		}
		defer delete(layer_counts, allocator)

		pair_count: u64
		for triangle_index in 0..<triangle_count {
			range_value, tri_err := layer_span_triangle_range(mesh, schedule, triangle_index)
			if tri_err != .None {
				layer_span_index_destroy(&index, allocator)
				return {}, tri_err
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
		index.triangle_ids = make([]contracts.Stable_ID, int(pair_count), allocator)
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

	chunk_table := make([]u64, chunk_count*layer_count, allocator)
	chunk_errors := make([]Layer_Span_Error, chunk_count, allocator)
	if chunk_table == nil || chunk_errors == nil {
		delete(chunk_table, allocator)
		delete(chunk_errors, allocator)
		layer_span_index_destroy(&index, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(chunk_table, allocator)
	defer delete(chunk_errors, allocator)

	chunk_size := (triangle_count+chunk_count-1)/chunk_count
	count_ctx := Layer_Span_Chunk_Context{
		mesh             = mesh,
		schedule         = schedule,
		triangle_ranges  = index.triangle_ranges,
		chunk_table      = chunk_table,
		chunk_errors     = chunk_errors,
		chunk_size       = chunk_size,
		triangle_count   = triangle_count,
		layer_count      = layer_count,
	}
	slicing_parallel_for(chunk_count, &count_ctx, layer_span_count_chunk)
	for err in chunk_errors {
		if err != .None {
			layer_span_index_destroy(&index, allocator)
			return {}, err
		}
	}

	// Prefix-sum chunk × layer counts in-place into per-chunk write offsets, preserving exact
	// ascending triangle order within every layer.
	pair_count: u64
	for layer_index in 0..<layer_count {
		layer_offset := pair_count
		layer_total: u64
		for c in 0..<chunk_count {
			slot := c*layer_count+layer_index
			cnt := chunk_table[slot]
			chunk_table[slot] = layer_offset+layer_total
			layer_total += cnt
		}
		if layer_total > u64(max(u32)) ||
		   pair_count > limits.max_pairs ||
		   layer_total > limits.max_pairs-pair_count {
			layer_span_index_destroy(&index, allocator)
			return {}, .Pair_Limit
		}
		index.layers[layer_index] = {
			offset = layer_offset,
			count  = u32(layer_total),
		}
		pair_count += layer_total
	}
	if pair_count > u64(max(int)) {
		layer_span_index_destroy(&index, allocator)
		return {}, .Pair_Limit
	}

	index.triangle_ids = make([]contracts.Stable_ID, int(pair_count), allocator)
	index.triangle_indices = make([]u32, int(pair_count), allocator)
	if pair_count > 0 &&
	   (index.triangle_ids == nil || index.triangle_indices == nil) {
		layer_span_index_destroy(&index, allocator)
		return {}, .Allocation_Failed
	}

	count_ctx.triangle_indices = index.triangle_indices
	count_ctx.triangle_ids = index.triangle_ids
	slicing_parallel_for(chunk_count, &count_ctx, layer_span_scatter_chunk)
	return index, .None
}

@(private = "file")
Layer_Span_Chunk_Context :: struct {
	mesh:             geometry.Canonical_Mesh,
	schedule:         Fixed_Layer_Schedule,
	triangle_ranges:  []Triangle_Layer_Range,
	chunk_table:      []u64,
	chunk_errors:     []Layer_Span_Error,
	triangle_indices: []u32,
	triangle_ids:     []contracts.Stable_ID,
	chunk_size:       int,
	triangle_count:   int,
	layer_count:      int,
}

@(private = "file")
layer_span_triangle_range :: proc(
	mesh: geometry.Canonical_Mesh,
	schedule: Fixed_Layer_Schedule,
	triangle_index: int,
) -> (Triangle_Layer_Range, Layer_Span_Error) {
	vertex_count := len(mesh.vertex_z)
	layer_count := len(schedule.layer_z)
	a := mesh.triangle_a[triangle_index]
	b := mesh.triangle_b[triangle_index]
	c := mesh.triangle_c[triangle_index]
	if u64(a) >= u64(vertex_count) ||
	   u64(b) >= u64(vertex_count) ||
	   u64(c) >= u64(vertex_count) {
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
	z0_key, z0_error := geometry.millimetres_to_micrometres(contracts.Millimetres(z0))
	z1_key, z1_error := geometry.millimetres_to_micrometres(contracts.Millimetres(z1))
	z2_key, z2_error := geometry.millimetres_to_micrometres(contracts.Millimetres(z2))
	if minimum_error != .None || maximum_error != .None ||
	   z0_error != .None || z1_error != .None || z2_error != .None {
		return {}, .Coordinate_Range
	}

	if z0_key == z1_key && z1_key == z2_key {
		layer_index := layer_lower_bound(schedule.layer_z, z0_key)
		if layer_index < layer_count && schedule.layer_z[layer_index] == z0_key {
			return {
				first_layer = u32(layer_index),
				layer_count = 1,
				kind        = .Quantized_Planar,
			}, .None
		}
		return {}, .None
	}
	first_layer := layer_lower_bound(schedule.layer_z, minimum_key)
	end_layer := layer_lower_bound(schedule.layer_z, maximum_key)
	if end_layer > first_layer {
		return {
			first_layer = u32(first_layer),
			layer_count = u32(end_layer-first_layer),
			kind        = .Crossing_Candidates,
		}, .None
	}
	return {}, .None
}

@(private = "file")
layer_span_count_chunk :: proc(ctx: ^Layer_Span_Chunk_Context, chunk_index: int) {
	start := chunk_index*ctx.chunk_size
	end := min(start+ctx.chunk_size, ctx.triangle_count)
	if start >= end {return}
	counts := ctx.chunk_table[chunk_index*ctx.layer_count:(chunk_index+1)*ctx.layer_count]
	for triangle_index in start..<end {
		range_value, err := layer_span_triangle_range(ctx.mesh, ctx.schedule, triangle_index)
		if err != .None {
			ctx.chunk_errors[chunk_index] = err
			return
		}
		ctx.triangle_ranges[triangle_index] = range_value
		for local_layer in 0..<int(range_value.layer_count) {
			counts[int(range_value.first_layer)+local_layer] += 1
		}
	}
}

@(private = "file")
layer_span_scatter_chunk :: proc(ctx: ^Layer_Span_Chunk_Context, chunk_index: int) {
	start := chunk_index*ctx.chunk_size
	end := min(start+ctx.chunk_size, ctx.triangle_count)
	if start >= end {return}
	cursors := ctx.chunk_table[chunk_index*ctx.layer_count:(chunk_index+1)*ctx.layer_count]
	for triangle_index in start..<end {
		range_value := ctx.triangle_ranges[triangle_index]
		for local_layer in 0..<int(range_value.layer_count) {
			layer_index := int(range_value.first_layer)+local_layer
			write_index := cursors[layer_index]
			ctx.triangle_indices[write_index] = u32(triangle_index)
			ctx.triangle_ids[write_index] = ctx.mesh.triangle_ids[triangle_index]
			cursors[layer_index] += 1
		}
	}
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
