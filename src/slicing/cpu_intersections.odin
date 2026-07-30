package slicing

import "core:mem"

import contracts "../contracts"
import geometry "../geometry"

Planar_Candidate_Kind :: enum u8 {
	Invalid,
	Quantized_Face,
	Exact_Edge,
	Exact_Face,
}

Planar_Candidate :: struct {
	layer_index:    u32,
	triangle_index: u32,
	triangle_id:    contracts.Stable_ID,
	kind:           Planar_Candidate_Kind,
	source_edge:    Triangle_Edge,
}

Intersection_Layer :: struct {
	segment_offset: u64,
	segment_count:  u32,
	planar_offset:  u64,
	planar_count:   u32,
}

Raw_Segment_SoA :: struct {
	layer_indices:    []u32,
	triangle_indices: []u32,
	segment_ids:      []contracts.Stable_ID,
	triangle_ids:     []contracts.Stable_ID,
	edge_a:           []Triangle_Edge,
	edge_b:           []Triangle_Edge,
	x0:               []f64,
	y0:               []f64,
	x1:               []f64,
	y1:               []f64,
}

CPU_Intersection_Result :: struct {
	layers:                []Intersection_Layer,
	segments:              Raw_Segment_SoA,
	planar_candidates:     []Planar_Candidate,
	tangent_count:         u64,
	degenerate_count:      u64,
	exact_predicate_count: u64,
}

CPU_Intersection_Limits :: struct {
	max_segments:          u64,
	max_planar_candidates: u64,
}

DEFAULT_CPU_INTERSECTION_LIMITS :: CPU_Intersection_Limits{
	max_segments = 1_000_000_000,
	max_planar_candidates = 100_000_000,
}

CPU_Intersection_Error :: enum u8 {
	None,
	Invalid_Mesh,
	Invalid_Schedule,
	Invalid_Index,
	Coordinate_Range,
	Arithmetic,
	Segment_Limit,
	Planar_Limit,
	Allocation_Failed,
}

Intersection_Pair_Kind :: enum u8 {
	None,
	Segment,
	Planar,
	Tangent,
	Degenerate,
}

Intersection_Pair_Evaluation :: struct {
	kind:                  Intersection_Pair_Kind,
	segment:               Triangle_Plane_Result,
	planar_kind:           Planar_Candidate_Kind,
	exact_predicate_count: u8,
}

cpu_intersections_build :: proc(
	mesh: geometry.Canonical_Mesh,
	schedule: Fixed_Layer_Schedule,
	span_index: Layer_Span_Index,
	limits := DEFAULT_CPU_INTERSECTION_LIMITS,
	allocator := context.allocator,
) -> (CPU_Intersection_Result, CPU_Intersection_Error) {
	triangle_count := len(mesh.triangle_ids)
	vertex_count := len(mesh.vertex_x)
	layer_count := len(schedule.layer_z)
	pair_count := len(span_index.triangle_ids)
	if triangle_count == 0 || vertex_count == 0 ||
	   len(mesh.vertex_y) != vertex_count ||
	   len(mesh.vertex_z) != vertex_count ||
	   len(mesh.triangle_a) != triangle_count ||
	   len(mesh.triangle_b) != triangle_count ||
	   len(mesh.triangle_c) != triangle_count {
		return {}, .Invalid_Mesh
	}
	if layer_count == 0 || len(schedule.layer_ids) != layer_count {
		return {}, .Invalid_Schedule
	}
	if len(span_index.layers) != layer_count ||
	   len(span_index.triangle_ranges) != triangle_count ||
	   len(span_index.triangle_indices) != pair_count {
		return {}, .Invalid_Index
	}

	result: CPU_Intersection_Result
	result.layers = make([]Intersection_Layer, layer_count, allocator)
	segment_counts := make([]u64, layer_count, allocator)
	planar_counts := make([]u64, layer_count, allocator)
	if result.layers == nil || segment_counts == nil || planar_counts == nil {
		delete(segment_counts, allocator)
		delete(planar_counts, allocator)
		cpu_intersections_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(segment_counts, allocator)
	defer delete(planar_counts, allocator)

	total_segments: u64
	total_planar: u64
	expected_pair_offset: u64
	for layer, layer_index in span_index.layers {
		if layer.offset != expected_pair_offset ||
		   u64(layer.count) > u64(pair_count)-expected_pair_offset {
			cpu_intersections_destroy(&result, allocator)
			return {}, .Invalid_Index
		}
		expected_pair_offset += u64(layer.count)
		for local_pair in 0..<int(layer.count) {
			pair_index := int(layer.offset)+local_pair
			triangle_index := span_index.triangle_indices[pair_index]
			evaluation, error := cpu_intersection_evaluate_pair(
				mesh,
				schedule,
				span_index,
				u32(layer_index),
				triangle_index,
				pair_index,
			)
			if error != .None {
				cpu_intersections_destroy(&result, allocator)
				return {}, error
			}
			result.exact_predicate_count +=
				u64(evaluation.exact_predicate_count)
			switch evaluation.kind {
			case .Segment:
				if total_segments >= limits.max_segments {
					cpu_intersections_destroy(&result, allocator)
					return {}, .Segment_Limit
				}
				total_segments += 1
				segment_counts[layer_index] += 1
			case .Planar:
				if total_planar >= limits.max_planar_candidates {
					cpu_intersections_destroy(&result, allocator)
					return {}, .Planar_Limit
				}
				total_planar += 1
				planar_counts[layer_index] += 1
			case .Tangent:
				result.tangent_count += 1
			case .Degenerate:
				result.degenerate_count += 1
			case .None:
			}
		}
	}
	if expected_pair_offset != u64(pair_count) {
		cpu_intersections_destroy(&result, allocator)
		return {}, .Invalid_Index
	}
	if total_segments > u64(max(int)) || total_planar > u64(max(int)) {
		cpu_intersections_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	segment_offset: u64
	planar_offset: u64
	for layer_index in 0..<layer_count {
		if segment_counts[layer_index] > u64(max(u32)) ||
		   planar_counts[layer_index] > u64(max(u32)) {
			cpu_intersections_destroy(&result, allocator)
			return {}, .Allocation_Failed
		}
		result.layers[layer_index] = {
			segment_offset = segment_offset,
			segment_count = u32(segment_counts[layer_index]),
			planar_offset = planar_offset,
			planar_count = u32(planar_counts[layer_index]),
		}
		segment_offset += segment_counts[layer_index]
		planar_offset += planar_counts[layer_index]
	}
	if !raw_segment_soa_allocate(
		&result.segments,
		int(total_segments),
		allocator,
	) {
		cpu_intersections_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	result.planar_candidates = make(
		[]Planar_Candidate,
		int(total_planar),
		allocator,
	)
	if total_planar > 0 && result.planar_candidates == nil {
		cpu_intersections_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	segment_cursors := make([]u64, layer_count, allocator)
	planar_cursors := make([]u64, layer_count, allocator)
	if segment_cursors == nil || planar_cursors == nil {
		delete(segment_cursors, allocator)
		delete(planar_cursors, allocator)
		cpu_intersections_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(segment_cursors, allocator)
	defer delete(planar_cursors, allocator)
	for layer, layer_index in result.layers {
		segment_cursors[layer_index] = layer.segment_offset
		planar_cursors[layer_index] = layer.planar_offset
	}
	for layer, layer_index in span_index.layers {
		for local_pair in 0..<int(layer.count) {
			pair_index := int(layer.offset)+local_pair
			triangle_index := span_index.triangle_indices[pair_index]
			evaluation, error := cpu_intersection_evaluate_pair(
				mesh,
				schedule,
				span_index,
				u32(layer_index),
				triangle_index,
				pair_index,
			)
			if error != .None {
				cpu_intersections_destroy(&result, allocator)
				return {}, error
			}
			switch evaluation.kind {
			case .Segment:
				write_index := segment_cursors[layer_index]
				cpu_intersection_write_segment(
					&result.segments,
					int(write_index),
					u32(layer_index),
					triangle_index,
					span_index.triangle_ids[pair_index],
					schedule.layer_ids[layer_index],
					evaluation.segment,
				)
				segment_cursors[layer_index] += 1
			case .Planar:
				write_index := planar_cursors[layer_index]
				result.planar_candidates[write_index] = {
					layer_index = u32(layer_index),
					triangle_index = triangle_index,
					triangle_id = span_index.triangle_ids[pair_index],
					kind = evaluation.planar_kind,
					source_edge = evaluation.segment.edge_a,
				}
				planar_cursors[layer_index] += 1
			case .None, .Tangent, .Degenerate:
			}
		}
	}
	return result, .None
}

cpu_intersection_evaluate_pair :: proc(
	mesh: geometry.Canonical_Mesh,
	schedule: Fixed_Layer_Schedule,
	span_index: Layer_Span_Index,
	layer_index, triangle_index: u32,
	pair_index: int,
) -> (Intersection_Pair_Evaluation, CPU_Intersection_Error) {
	if u64(layer_index) >= u64(len(schedule.layer_z)) ||
	   u64(triangle_index) >= u64(len(mesh.triangle_ids)) ||
	   pair_index < 0 || pair_index >= len(span_index.triangle_ids) ||
	   mesh.triangle_ids[triangle_index] != span_index.triangle_ids[pair_index] {
		return {}, .Invalid_Index
	}
	range_value := span_index.triangle_ranges[triangle_index]
	range_end := u64(range_value.first_layer)+u64(range_value.layer_count)
	if u64(layer_index) < u64(range_value.first_layer) ||
	   u64(layer_index) >= range_end {
		return {}, .Invalid_Index
	}
	if range_value.kind == .Quantized_Planar {
		return {
			kind = .Planar,
			planar_kind = .Quantized_Face,
		}, .None
	}
	if range_value.kind != .Crossing_Candidates {
		return {}, .Invalid_Index
	}
	a := mesh.triangle_a[triangle_index]
	b := mesh.triangle_b[triangle_index]
	c := mesh.triangle_c[triangle_index]
	vertex_count := len(mesh.vertex_x)
	if u64(a) >= u64(vertex_count) ||
	   u64(b) >= u64(vertex_count) ||
	   u64(c) >= u64(vertex_count) {
		return {}, .Invalid_Mesh
	}
	vertex_indices := [3]u32{a, b, c}
	vertex_x: [3]f64
	vertex_y: [3]f64
	vertex_z: [3]f64
	for vertex_index, local_index in vertex_indices {
		vertex_x[local_index] = mesh.vertex_x[vertex_index]
		vertex_y[local_index] = mesh.vertex_y[vertex_index]
		vertex_z[local_index] = mesh.vertex_z[vertex_index]
	}
	intersection, intersection_error := triangle_plane_intersect(
		vertex_x,
		vertex_y,
		vertex_z,
		schedule.layer_z[layer_index],
	)
	if intersection_error == .Invalid_Coordinate {
		return {}, .Coordinate_Range
	}
	if intersection_error != .None {return {}, .Arithmetic}
	evaluation := Intersection_Pair_Evaluation{
		segment = intersection,
		exact_predicate_count = intersection.exact_predicate_count,
	}
	switch intersection.kind {
	case .None:               evaluation.kind = .None
	case .Segment:            evaluation.kind = .Segment
	case .Tangent_Vertex:     evaluation.kind = .Tangent
	case .Degenerate_Segment: evaluation.kind = .Degenerate
	case .Coplanar_Edge:
		evaluation.kind = .Planar
		evaluation.planar_kind = .Exact_Edge
	case .Coplanar_Face:
		evaluation.kind = .Planar
		evaluation.planar_kind = .Exact_Face
	}
	return evaluation, .None
}

cpu_intersection_write_segment :: proc(
	segments: ^Raw_Segment_SoA,
	write_index: int,
	layer_index, triangle_index: u32,
	triangle_id, layer_id: contracts.Stable_ID,
	segment: Triangle_Plane_Result,
) {
	segments.layer_indices[write_index] = layer_index
	segments.triangle_indices[write_index] = triangle_index
	segments.segment_ids[write_index] = contracts.stable_id_child(
		triangle_id,
		.Segment,
		u64(layer_id),
	)
	segments.triangle_ids[write_index] = triangle_id
	segments.edge_a[write_index] = segment.edge_a
	segments.edge_b[write_index] = segment.edge_b
	segments.x0[write_index] = segment.point_a.x
	segments.y0[write_index] = segment.point_a.y
	segments.x1[write_index] = segment.point_b.x
	segments.y1[write_index] = segment.point_b.y
}

raw_segment_soa_allocate :: proc(
	segments: ^Raw_Segment_SoA,
	count: int,
	allocator: mem.Allocator,
) -> bool {
	segments.layer_indices = make([]u32, count, allocator)
	segments.triangle_indices = make([]u32, count, allocator)
	segments.segment_ids = make([]contracts.Stable_ID, count, allocator)
	segments.triangle_ids = make([]contracts.Stable_ID, count, allocator)
	segments.edge_a = make([]Triangle_Edge, count, allocator)
	segments.edge_b = make([]Triangle_Edge, count, allocator)
	segments.x0 = make([]f64, count, allocator)
	segments.y0 = make([]f64, count, allocator)
	segments.x1 = make([]f64, count, allocator)
	segments.y1 = make([]f64, count, allocator)
	if count == 0 {return true}
	return segments.layer_indices != nil &&
		segments.triangle_indices != nil &&
		segments.segment_ids != nil &&
		segments.triangle_ids != nil &&
		segments.edge_a != nil &&
		segments.edge_b != nil &&
		segments.x0 != nil &&
		segments.y0 != nil &&
		segments.x1 != nil &&
		segments.y1 != nil
}

cpu_intersections_destroy :: proc(
	result: ^CPU_Intersection_Result,
	allocator := context.allocator,
) {
	delete(result.layers, allocator)
	delete(result.segments.layer_indices, allocator)
	delete(result.segments.triangle_indices, allocator)
	delete(result.segments.segment_ids, allocator)
	delete(result.segments.triangle_ids, allocator)
	delete(result.segments.edge_a, allocator)
	delete(result.segments.edge_b, allocator)
	delete(result.segments.x0, allocator)
	delete(result.segments.y0, allocator)
	delete(result.segments.x1, allocator)
	delete(result.segments.y1, allocator)
	delete(result.planar_candidates, allocator)
	result^ = {}
}
