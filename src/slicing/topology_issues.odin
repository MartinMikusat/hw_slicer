package slicing

import "core:mem"

import contracts "../contracts"
import geometry "../geometry"

TOPOLOGY_ISSUE_REPORT_HASH_SCHEMA_VERSION :: u32(1)

Topology_Issue_Code :: enum u8 {
	Invalid,
	Open_Chain,
	Degenerate_Loop,
	Non_Manifold_Vertex,
}

Topology_Issue :: struct {
	stable_id:        contracts.Stable_ID,
	entity_id:        contracts.Stable_ID,
	code:             Topology_Issue_Code,
	layer_index:      u32,
	entity_index:     u32,
	point_a:          Snapped_Point,
	point_b:          Snapped_Point,
	reference_offset: u64,
	reference_count:  u32,
}

Topology_Issue_Segment_Reference :: struct {
	segment_index:  u32,
	segment_id:     contracts.Stable_ID,
	triangle_index: u32,
	triangle_id:    contracts.Stable_ID,
	edge_a:         Triangle_Edge,
	edge_b:         Triangle_Edge,
}

Topology_Issue_Report :: struct {
	issues:                    []Topology_Issue,
	segment_references:        []Topology_Issue_Segment_Reference,
	open_chain_count:          u64,
	degenerate_loop_count:     u64,
	non_manifold_vertex_count: u64,
}

Topology_Issue_Limits :: struct {
	max_issues:             u64,
	max_segment_references: u64,
}

DEFAULT_TOPOLOGY_ISSUE_LIMITS :: Topology_Issue_Limits{
	max_issues = 100_000_000,
	max_segment_references = 2_000_000_000,
}

Topology_Issue_Error :: enum u8 {
	None,
	Invalid_Input,
	Issue_Limit,
	Reference_Limit,
	Allocation_Failed,
	Arithmetic,
}

topology_issue_report_build :: proc(
	topology: Topology_Result,
	segments: Snapped_Segment_Result,
	limits := DEFAULT_TOPOLOGY_ISSUE_LIMITS,
	allocator := context.allocator,
) -> (Topology_Issue_Report, Topology_Issue_Error) {
	segment_count := len(segments.segments.segment_ids)
	_, segments_valid := snapped_segment_result_hash({}, segments)
	_, topology_valid := topology_result_hash(
		{},
		segment_count,
		topology,
	)
	if !segments_valid || !topology_valid ||
	   len(topology.layers) != len(segments.layers) {
		return {}, .Invalid_Input
	}

	issue_count: u64
	reference_count: u64
	open_chain_count: u64
	degenerate_loop_count: u64
	non_manifold_vertex_count: u64
	for layer, layer_index in topology.layers {
		path_start := int(layer.path_offset)
		path_end := path_start+int(layer.path_count)
		for path in topology.paths[path_start:path_end] {
			if path.layer_index != u32(layer_index) {
				return {}, .Invalid_Input
			}
			switch path.kind {
			case .Open_Chain:
				open_chain_count += 1
			case .Degenerate_Loop:
				degenerate_loop_count += 1
			case .Loop:
				continue
			case .Invalid:
				return {}, .Invalid_Input
			}
			issue_count += 1
			if reference_count >
			   max(u64)-u64(path.segment_count) {
				return {}, .Arithmetic
			}
			reference_count += u64(path.segment_count)
		}
		vertex_start := int(layer.vertex_offset)
		vertex_end := vertex_start+int(layer.vertex_count)
		for vertex in topology.vertices[vertex_start:vertex_end] {
			if vertex.layer_index != u32(layer_index) {
				return {}, .Invalid_Input
			}
			if vertex.degree <= 2 {continue}
			non_manifold_vertex_count += 1
			issue_count += 1
			if reference_count > max(u64)-u64(vertex.degree) {
				return {}, .Arithmetic
			}
			reference_count += u64(vertex.degree)
		}
	}
	if open_chain_count != topology.open_chain_count ||
	   degenerate_loop_count != topology.degenerate_loop_count ||
	   non_manifold_vertex_count !=
	   	topology.non_manifold_vertex_count {
		return {}, .Invalid_Input
	}
	if issue_count > limits.max_issues ||
	   issue_count > u64(max(int)) {
		return {}, .Issue_Limit
	}
	if reference_count > limits.max_segment_references ||
	   reference_count > u64(max(int)) {
		return {}, .Reference_Limit
	}

	result := Topology_Issue_Report{
		issues = make([]Topology_Issue, int(issue_count), allocator),
		segment_references = make(
			[]Topology_Issue_Segment_Reference,
			int(reference_count),
			allocator,
		),
		open_chain_count = open_chain_count,
		degenerate_loop_count = degenerate_loop_count,
		non_manifold_vertex_count = non_manifold_vertex_count,
	}
	if issue_count > 0 && result.issues == nil ||
	   reference_count > 0 && result.segment_references == nil {
		topology_issue_report_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}

	issue_write := 0
	reference_write := 0
	for layer in topology.layers {
		path_start := int(layer.path_offset)
		path_end := path_start+int(layer.path_count)
		for path, local_path_index in topology.paths[path_start:path_end] {
			code: Topology_Issue_Code
			switch path.kind {
			case .Open_Chain:
				code = .Open_Chain
			case .Degenerate_Loop:
				code = .Degenerate_Loop
			case .Loop:
				continue
			case .Invalid:
				topology_issue_report_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			point_a, point_a_ok := topology_issue_path_point(
				topology,
				path,
				0,
			)
			point_b, point_b_ok := topology_issue_path_point(
				topology,
				path,
				path.vertex_count-1,
			)
			if !point_a_ok || !point_b_ok {
				topology_issue_report_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			result.issues[issue_write] = {
				stable_id = contracts.stable_id_child(
					path.id,
					.Topology_Issue,
					0,
				),
				entity_id = path.id,
				code = code,
				layer_index = path.layer_index,
				entity_index = u32(path_start+local_path_index),
				point_a = point_a,
				point_b = point_b,
				reference_offset = u64(reference_write),
				reference_count = path.segment_count,
			}
			for local_reference in 0..<int(path.segment_count) {
				path_reference_index :=
					int(path.segment_offset)+local_reference
				segment_index :=
					topology.path_segment_indices[path_reference_index]
				if !topology_issue_reference_write(
					&result.segment_references[reference_write],
					segments,
					segment_index,
					path.layer_index,
				) {
					topology_issue_report_destroy(&result, allocator)
					return {}, .Invalid_Input
				}
				reference_write += 1
			}
			issue_write += 1
		}

		vertex_start := int(layer.vertex_offset)
		vertex_end := vertex_start+int(layer.vertex_count)
		for vertex, local_vertex_index in
		    topology.vertices[vertex_start:vertex_end] {
			if vertex.degree <= 2 {continue}
			result.issues[issue_write] = {
				stable_id = contracts.stable_id_child(
					vertex.id,
					.Topology_Issue,
					0,
				),
				entity_id = vertex.id,
				code = .Non_Manifold_Vertex,
				layer_index = vertex.layer_index,
				entity_index = u32(vertex_start+local_vertex_index),
				point_a = vertex.point,
				point_b = vertex.point,
				reference_offset = u64(reference_write),
				reference_count = vertex.degree,
			}
			layer_segments := segments.layers[vertex.layer_index]
			found: u32
			for local_segment in 0..<int(layer_segments.count) {
				segment_index :=
					u32(int(layer_segments.offset)+local_segment)
				index := int(segment_index)
				point_a := Snapped_Point{
					segments.segments.x0[index],
					segments.segments.y0[index],
				}
				point_b := Snapped_Point{
					segments.segments.x1[index],
					segments.segments.y1[index],
				}
				if point_a != vertex.point && point_b != vertex.point {
					continue
				}
				if found >= vertex.degree ||
				   !topology_issue_reference_write(
				   	&result.segment_references[reference_write],
				   	segments,
				   	segment_index,
				   	vertex.layer_index,
				   ) {
					topology_issue_report_destroy(&result, allocator)
					return {}, .Invalid_Input
				}
				found += 1
				reference_write += 1
			}
			if found != vertex.degree {
				topology_issue_report_destroy(&result, allocator)
				return {}, .Invalid_Input
			}
			issue_write += 1
		}
	}
	if issue_write != len(result.issues) ||
	   reference_write != len(result.segment_references) {
		topology_issue_report_destroy(&result, allocator)
		return {}, .Arithmetic
	}
	return result, .None
}

topology_issue_report_hash :: proc(
	topology_hash: contracts.Content_Hash,
	report: Topology_Issue_Report,
) -> (contracts.Content_Hash, bool) {
	issue_count := u64(len(report.issues))
	if report.open_chain_count > issue_count ||
	   report.degenerate_loop_count >
	   	issue_count-report.open_chain_count ||
	   report.non_manifold_vertex_count >
	   	issue_count-
	   	report.open_chain_count-
	   	report.degenerate_loop_count ||
	   report.open_chain_count+
	   	report.degenerate_loop_count+
	   	report.non_manifold_vertex_count != issue_count {
		return {}, false
	}
	expected_reference_offset: u64
	open_chain_count: u64
	degenerate_loop_count: u64
	non_manifold_vertex_count: u64
	for issue in report.issues {
		if issue.stable_id == contracts.INVALID_STABLE_ID ||
		   issue.entity_id == contracts.INVALID_STABLE_ID ||
		   issue.stable_id != contracts.stable_id_child(
		   	issue.entity_id,
		   	.Topology_Issue,
		   	0,
		   ) ||
		   issue.reference_count == 0 ||
		   issue.reference_offset != expected_reference_offset ||
		   geometry.point_2_validate({
		   	issue.point_a.x,
		   	issue.point_a.y,
		   }) != .None ||
		   geometry.point_2_validate({
		   	issue.point_b.x,
		   	issue.point_b.y,
		   }) != .None ||
		   u64(issue.reference_count) >
		   	u64(len(report.segment_references))-
		   	expected_reference_offset {
			return {}, false
		}
		switch issue.code {
		case .Open_Chain:
			open_chain_count += 1
		case .Degenerate_Loop:
			degenerate_loop_count += 1
		case .Non_Manifold_Vertex:
			if issue.point_a != issue.point_b {return {}, false}
			non_manifold_vertex_count += 1
		case .Invalid:
			return {}, false
		}
		expected_reference_offset += u64(issue.reference_count)
	}
	if expected_reference_offset !=
	   u64(len(report.segment_references)) ||
	   open_chain_count != report.open_chain_count ||
	   degenerate_loop_count != report.degenerate_loop_count ||
	   non_manifold_vertex_count !=
	   	report.non_manifold_vertex_count {
		return {}, false
	}
	for reference in report.segment_references {
		if reference.segment_id == contracts.INVALID_STABLE_ID ||
		   reference.triangle_id == contracts.INVALID_STABLE_ID ||
		   reference.edge_a == .Invalid ||
		   reference.edge_b == .Invalid {
			return {}, false
		}
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/topology-issue-report",
		TOPOLOGY_ISSUE_REPORT_HASH_SCHEMA_VERSION,
	)
	contracts.canonical_hash_append_content_hash(&hash, topology_hash)
	contracts.canonical_hash_append_u64(&hash, report.open_chain_count)
	contracts.canonical_hash_append_u64(
		&hash,
		report.degenerate_loop_count,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		report.non_manifold_vertex_count,
	)
	contracts.canonical_hash_append_u64(&hash, u64(len(report.issues)))
	for issue in report.issues {
		contracts.canonical_hash_append_stable_id(&hash, issue.stable_id)
		contracts.canonical_hash_append_stable_id(&hash, issue.entity_id)
		contracts.canonical_hash_append_u8(&hash, u8(issue.code))
		contracts.canonical_hash_append_u32(&hash, issue.layer_index)
		contracts.canonical_hash_append_u32(&hash, issue.entity_index)
		contracts.canonical_hash_append_i64(&hash, i64(issue.point_a.x))
		contracts.canonical_hash_append_i64(&hash, i64(issue.point_a.y))
		contracts.canonical_hash_append_i64(&hash, i64(issue.point_b.x))
		contracts.canonical_hash_append_i64(&hash, i64(issue.point_b.y))
		contracts.canonical_hash_append_u64(
			&hash,
			issue.reference_offset,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			issue.reference_count,
		)
	}
	contracts.canonical_hash_append_u64(
		&hash,
		u64(len(report.segment_references)),
	)
	for reference in report.segment_references {
		contracts.canonical_hash_append_u32(
			&hash,
			reference.segment_index,
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			reference.segment_id,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			reference.triangle_index,
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			reference.triangle_id,
		)
		contracts.canonical_hash_append_u8(&hash, u8(reference.edge_a))
		contracts.canonical_hash_append_u8(&hash, u8(reference.edge_b))
	}
	return contracts.canonical_hash_final(&hash), true
}

topology_issue_path_point :: proc(
	topology: Topology_Result,
	path: Topology_Path,
	local_index: u32,
) -> (Snapped_Point, bool) {
	if local_index >= path.vertex_count ||
	   path.vertex_offset+u64(local_index) >=
	   	u64(len(topology.path_vertex_indices)) {
		return {}, false
	}
	vertex_index :=
		topology.path_vertex_indices[int(path.vertex_offset)+int(local_index)]
	if u64(vertex_index) >= u64(len(topology.vertices)) {
		return {}, false
	}
	return topology.vertices[vertex_index].point, true
}

topology_issue_reference_write :: proc(
	output: ^Topology_Issue_Segment_Reference,
	segments: Snapped_Segment_Result,
	segment_index: u32,
	layer_index: u32,
) -> bool {
	if u64(segment_index) >= u64(len(segments.segments.segment_ids)) {
		return false
	}
	index := int(segment_index)
	if segments.segments.layer_indices[index] != layer_index {
		return false
	}
	output^ = {
		segment_index = segment_index,
		segment_id = segments.segments.segment_ids[index],
		triangle_index = segments.segments.triangle_indices[index],
		triangle_id = segments.segments.triangle_ids[index],
		edge_a = segments.segments.edge_a[index],
		edge_b = segments.segments.edge_b[index],
	}
	return true
}

topology_issue_report_destroy :: proc(
	report: ^Topology_Issue_Report,
	allocator := context.allocator,
) {
	delete(report.issues, allocator)
	delete(report.segment_references, allocator)
	report^ = {}
}
