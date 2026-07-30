package slicing

import "core:mem"
import "core:slice"

import contracts "../contracts"
import geometry "../geometry"

Planar_Incidence_Kind :: enum u8 {
	Invalid,
	Face,
	Third_Below,
	Third_Above,
}

Planar_Incidence :: struct {
	layer_index:    u32,
	point_a:        Snapped_Point,
	point_b:        Snapped_Point,
	triangle_index: u32,
	triangle_id:    contracts.Stable_ID,
	source_edge:    Triangle_Edge,
	kind:           Planar_Incidence_Kind,
}

Planar_Ownership_Result :: struct {
	layers:                   []Snapped_Layer,
	segments:                 Snapped_Segment_SoA,
	incidence_count:          u64,
	unresolved_group_count:   u64,
	suppressed_group_count:   u64,
	collapsed_incidence_count: u64,
	exact_predicate_count:    u64,
}

Planar_Ownership_Limits :: struct {
	max_incidences: u64,
	max_segments:   u64,
}

DEFAULT_PLANAR_OWNERSHIP_LIMITS :: Planar_Ownership_Limits{
	max_incidences = 300_000_000,
	max_segments = 100_000_000,
}

Planar_Ownership_Error :: enum u8 {
	None,
	Invalid_Input,
	Coordinate_Range,
	Incidence_Limit,
	Segment_Limit,
	Allocation_Failed,
}

planar_ownership_resolve :: proc(
	mesh: geometry.Canonical_Mesh,
	schedule: Fixed_Layer_Schedule,
	intersections: CPU_Intersection_Result,
	limits := DEFAULT_PLANAR_OWNERSHIP_LIMITS,
	allocator := context.allocator,
) -> (Planar_Ownership_Result, Planar_Ownership_Error) {
	layer_count := len(schedule.layer_z)
	incidences, collapsed_incidence_count, exact_predicate_count,
	incidence_error := planar_incidences_collect(
		mesh,
		schedule,
		intersections,
		limits,
		allocator,
	)
	if incidence_error != .None {return {}, incidence_error}
	defer delete(incidences, allocator)

	result := Planar_Ownership_Result{
		incidence_count = u64(len(incidences)),
		collapsed_incidence_count = collapsed_incidence_count,
		exact_predicate_count = exact_predicate_count,
	}
	result.layers = make([]Snapped_Layer, layer_count, allocator)
	layer_counts := make([]u64, layer_count, allocator)
	if result.layers == nil || layer_counts == nil {
		delete(layer_counts, allocator)
		planar_ownership_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(layer_counts, allocator)
	output_count: u64
	for group_start := 0; group_start < len(incidences); {
		group_end := planar_incidence_group_end(incidences, group_start)
		emit, unresolved := planar_incidence_group_should_emit(
			incidences[group_start:group_end],
		)
		if unresolved {
			result.unresolved_group_count += 1
		} else if emit {
			if output_count >= limits.max_segments {
				planar_ownership_destroy(&result, allocator)
				return {}, .Segment_Limit
			}
			layer_index := incidences[group_start].layer_index
			layer_counts[layer_index] += 1
			output_count += 1
		} else {
			result.suppressed_group_count += 1
		}
		group_start = group_end
	}
	if output_count > u64(max(int)) {
		planar_ownership_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	output_offset: u64
	for layer_count_value, layer_index in layer_counts {
		if layer_count_value > u64(max(u32)) {
			planar_ownership_destroy(&result, allocator)
			return {}, .Allocation_Failed
		}
		result.layers[layer_index] = {
			offset = output_offset,
			count = u32(layer_count_value),
		}
		output_offset += layer_count_value
	}
	if !snapped_segment_soa_allocate(
		&result.segments,
		int(output_count),
		allocator,
	) {
		planar_ownership_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	write_index := 0
	for group_start := 0; group_start < len(incidences); {
		group_end := planar_incidence_group_end(incidences, group_start)
		group := incidences[group_start:group_end]
		emit, unresolved := planar_incidence_group_should_emit(group)
		if emit && !unresolved {
			owner := planar_incidence_group_owner(group)
			layer_id := schedule.layer_ids[owner.layer_index]
			result.segments.layer_indices[write_index] =
				owner.layer_index
			result.segments.triangle_indices[write_index] =
				owner.triangle_index
			result.segments.segment_ids[write_index] =
				contracts.stable_id_child(
					owner.triangle_id,
					.Segment,
					u64(layer_id),
				)
			result.segments.triangle_ids[write_index] =
				owner.triangle_id
			result.segments.edge_a[write_index] = owner.source_edge
			result.segments.edge_b[write_index] = owner.source_edge
			result.segments.x0[write_index] = owner.point_a.x
			result.segments.y0[write_index] = owner.point_a.y
			result.segments.x1[write_index] = owner.point_b.x
			result.segments.y1[write_index] = owner.point_b.y
			write_index += 1
		}
		group_start = group_end
	}
	return result, .None
}

planar_incidences_collect :: proc(
	mesh: geometry.Canonical_Mesh,
	schedule: Fixed_Layer_Schedule,
	intersections: CPU_Intersection_Result,
	limits: Planar_Ownership_Limits,
	allocator: mem.Allocator,
) -> (
	incidences: []Planar_Incidence,
	collapsed_incidence_count: u64,
	exact_predicate_count: u64,
	error: Planar_Ownership_Error,
) {
	layer_count := len(schedule.layer_z)
	triangle_count := len(mesh.triangle_ids)
	vertex_count := len(mesh.vertex_x)
	candidate_count := len(intersections.planar_candidates)
	if layer_count == 0 || len(schedule.layer_ids) != layer_count ||
	   len(intersections.layers) != layer_count ||
	   triangle_count == 0 || vertex_count == 0 ||
	   len(mesh.vertex_y) != vertex_count ||
	   len(mesh.vertex_z) != vertex_count ||
	   len(mesh.triangle_a) != triangle_count ||
	   len(mesh.triangle_b) != triangle_count ||
	   len(mesh.triangle_c) != triangle_count ||
	   candidate_count > max(int)/3 {
		return nil, 0, 0, .Invalid_Input
	}
	maximum_incidence_count := u64(candidate_count)*3
	if maximum_incidence_count > limits.max_incidences ||
	   maximum_incidence_count > u64(max(int)) {
		return nil, 0, 0, .Incidence_Limit
	}
	incidences = make(
		[]Planar_Incidence,
		int(maximum_incidence_count),
		allocator,
	)
	if maximum_incidence_count > 0 && incidences == nil {
		return nil, 0, 0, .Allocation_Failed
	}
	incidence_write := 0
	for candidate in intersections.planar_candidates {
		if u64(candidate.layer_index) >= u64(layer_count) ||
		   u64(candidate.triangle_index) >= u64(triangle_count) ||
		   candidate.triangle_id !=
		   	mesh.triangle_ids[candidate.triangle_index] {
			delete(incidences, allocator)
			return nil, 0, 0, .Invalid_Input
		}
		switch candidate.kind {
		case .Quantized_Face, .Exact_Face:
			face_edges := [3]Triangle_Edge{.AB, .BC, .CA}
			for edge in face_edges {
				incidence, incidence_ok :=
					planar_incidence_from_edge(
						mesh,
						candidate,
						edge,
						.Face,
					)
				if !incidence_ok {
					delete(incidences, allocator)
					return nil, 0, 0, .Coordinate_Range
				}
				if incidence.point_a == incidence.point_b {
					collapsed_incidence_count += 1
					continue
				}
				incidences[incidence_write] = incidence
				incidence_write += 1
			}
		case .Exact_Edge:
			if candidate.source_edge == .Invalid {
				delete(incidences, allocator)
				return nil, 0, 0, .Invalid_Input
			}
			third_vertex := planar_edge_third_vertex(
				candidate.source_edge,
			)
			triangle_vertices, vertices_ok := planar_triangle_vertices(
				mesh,
				candidate.triangle_index,
			)
			if !vertices_ok {
				delete(incidences, allocator)
				return nil, 0, 0, .Invalid_Input
			}
			side, side_error := geometry.plane_side_classify(
				contracts.Millimetres(
					mesh.vertex_z[triangle_vertices[third_vertex]],
				),
				schedule.layer_z[candidate.layer_index],
			)
			if side_error != .None || side.side == .On {
				delete(incidences, allocator)
				return nil, 0, 0, .Coordinate_Range
			}
			exact_predicate_count += 1
			incidence_kind := Planar_Incidence_Kind.Third_Below
			if side.side == .Above {incidence_kind = .Third_Above}
			incidence, incidence_ok := planar_incidence_from_edge(
				mesh,
				candidate,
				candidate.source_edge,
				incidence_kind,
			)
			if !incidence_ok {
				delete(incidences, allocator)
				return nil, 0, 0, .Coordinate_Range
			}
			if incidence.point_a == incidence.point_b {
				collapsed_incidence_count += 1
				continue
			}
			incidences[incidence_write] = incidence
			incidence_write += 1
		case .Invalid:
			delete(incidences, allocator)
			return nil, 0, 0, .Invalid_Input
		}
	}
	incidences = incidences[:incidence_write]
	slice.sort_by(incidences, planar_incidence_less)
	return incidences, collapsed_incidence_count, exact_predicate_count, .None
}

planar_incidence_from_edge :: proc(
	mesh: geometry.Canonical_Mesh,
	candidate: Planar_Candidate,
	edge: Triangle_Edge,
	kind: Planar_Incidence_Kind,
) -> (Planar_Incidence, bool) {
	triangle_vertices, vertices_ok := planar_triangle_vertices(
		mesh,
		candidate.triangle_index,
	)
	if !vertices_ok {return {}, false}
	a, b := planar_edge_vertices(edge)
	if a < 0 || b < 0 {return {}, false}
	vertex_a := triangle_vertices[a]
	vertex_b := triangle_vertices[b]
	x0, x0_error := geometry.millimetres_to_micrometres(
		contracts.Millimetres(mesh.vertex_x[vertex_a]),
	)
	y0, y0_error := geometry.millimetres_to_micrometres(
		contracts.Millimetres(mesh.vertex_y[vertex_a]),
	)
	x1, x1_error := geometry.millimetres_to_micrometres(
		contracts.Millimetres(mesh.vertex_x[vertex_b]),
	)
	y1, y1_error := geometry.millimetres_to_micrometres(
		contracts.Millimetres(mesh.vertex_y[vertex_b]),
	)
	if x0_error != .None || y0_error != .None ||
	   x1_error != .None || y1_error != .None {
		return {}, false
	}
	incidence := Planar_Incidence{
		layer_index = candidate.layer_index,
		point_a = {x0, y0},
		point_b = {x1, y1},
		triangle_index = candidate.triangle_index,
		triangle_id = candidate.triangle_id,
		source_edge = edge,
		kind = kind,
	}
	if snapped_point_less(incidence.point_b, incidence.point_a) {
		incidence.point_a, incidence.point_b =
			incidence.point_b, incidence.point_a
	}
	return incidence, true
}

planar_triangle_vertices :: proc(
	mesh: geometry.Canonical_Mesh,
	triangle_index: u32,
) -> ([3]u32, bool) {
	if u64(triangle_index) >= u64(len(mesh.triangle_ids)) {
		return {}, false
	}
	vertices := [3]u32{
		mesh.triangle_a[triangle_index],
		mesh.triangle_b[triangle_index],
		mesh.triangle_c[triangle_index],
	}
	for vertex in vertices {
		if u64(vertex) >= u64(len(mesh.vertex_x)) {return {}, false}
	}
	return vertices, true
}

planar_edge_vertices :: proc(edge: Triangle_Edge) -> (int, int) {
	switch edge {
	case .AB: return 0, 1
	case .BC: return 1, 2
	case .CA: return 2, 0
	case .Invalid:
	}
	return -1, -1
}

planar_edge_third_vertex :: proc(edge: Triangle_Edge) -> int {
	switch edge {
	case .AB: return 2
	case .BC: return 0
	case .CA: return 1
	case .Invalid:
	}
	return -1
}

planar_incidence_less :: proc(a, b: Planar_Incidence) -> bool {
	if a.layer_index != b.layer_index {
		return a.layer_index < b.layer_index
	}
	if snapped_point_less(a.point_a, b.point_a) {return true}
	if snapped_point_less(b.point_a, a.point_a) {return false}
	if snapped_point_less(a.point_b, b.point_b) {return true}
	if snapped_point_less(b.point_b, a.point_b) {return false}
	if a.triangle_id != b.triangle_id {
		return u64(a.triangle_id) < u64(b.triangle_id)
	}
	return a.source_edge < b.source_edge
}

planar_incidence_group_end :: proc(
	incidences: []Planar_Incidence,
	start: int,
) -> int {
	end := start+1
	for end < len(incidences) &&
	    incidences[end].layer_index == incidences[start].layer_index &&
	    incidences[end].point_a == incidences[start].point_a &&
	    incidences[end].point_b == incidences[start].point_b {
		end += 1
	}
	return end
}

planar_incidence_group_should_emit :: proc(
	group: []Planar_Incidence,
) -> (emit, unresolved: bool) {
	if len(group) == 0 || len(group) > 2 {return false, true}
	above_count := 0
	for incidence in group {
		if incidence.kind == .Third_Above {above_count += 1}
	}
	return above_count%2 == 1, false
}

planar_incidence_group_owner :: proc(
	group: []Planar_Incidence,
) -> Planar_Incidence {
	owner: Planar_Incidence
	for incidence in group {
		if incidence.kind != .Third_Above {continue}
		if owner.kind == .Invalid ||
		   u64(incidence.triangle_id) < u64(owner.triangle_id) {
			owner = incidence
		}
	}
	return owner
}

planar_ownership_destroy :: proc(
	result: ^Planar_Ownership_Result,
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
	delete(result.segments.x0_error_um, allocator)
	delete(result.segments.y0_error_um, allocator)
	delete(result.segments.x1_error_um, allocator)
	delete(result.segments.y1_error_um, allocator)
	result^ = {}
}
