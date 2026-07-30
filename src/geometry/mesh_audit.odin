package geometry

import "core:math"
import "core:slice"

import contracts "../contracts"

Mesh_Issue_Code :: enum u8 {
	Invalid,
	Degenerate_Triangle,
	Boundary_Edge,
	Non_Manifold_Edge,
	Inconsistent_Winding,
	Duplicate_Face,
}

Mesh_Audit_Issue :: struct {
	stable_id:       contracts.Stable_ID,
	code:            Mesh_Issue_Code,
	has_edge:        bool,
	edge_a:          Point_3,
	edge_b:          Point_3,
	triangle_offset: u64,
	triangle_count:  u32,
}

Mesh_Audit_Result :: struct {
	issues:                     []Mesh_Audit_Issue,
	triangle_ids:               []contracts.Stable_ID,
	welded_vertex_count:        u64,
	degenerate_triangle_count:  u64,
	duplicate_face_group_count: u64,
	boundary_edge_count:        u64,
	non_manifold_edge_count:    u64,
	inconsistent_winding_count: u64,
}

Mesh_Audit_Limits :: struct {
	max_vertices:            u64,
	max_triangles:           u64,
	max_edges:               u64,
	max_issues:              u64,
	max_issue_triangle_refs: u64,
}

DEFAULT_MESH_AUDIT_LIMITS :: Mesh_Audit_Limits{
	max_vertices = 100_000_000,
	max_triangles = 100_000_000,
	max_edges = 300_000_000,
	max_issues = 400_000_000,
	max_issue_triangle_refs = 400_000_000,
}

Mesh_Audit_Error :: enum u8 {
	None,
	Invalid_Input,
	Vertex_Limit,
	Triangle_Limit,
	Edge_Limit,
	Issue_Limit,
	Arithmetic,
	Allocation_Failed,
}

Mesh_Audit_Vertex_Record :: struct {
	x, y, z:     f64,
	source_index: u32,
}

Mesh_Audit_Edge_Record :: struct {
	vertex_a:      u32,
	vertex_b:      u32,
	triangle_index: u32,
	forward:       bool,
}

Mesh_Audit_Face_Record :: struct {
	vertex_a:      u32,
	vertex_b:      u32,
	vertex_c:      u32,
	triangle_index: u32,
}

mesh_audit :: proc(
	mesh: Canonical_Mesh,
	limits := DEFAULT_MESH_AUDIT_LIMITS,
	allocator := context.allocator,
) -> (Mesh_Audit_Result, Mesh_Audit_Error) {
	_, mesh_valid := canonical_mesh_hash(mesh)
	if !mesh_valid {return {}, .Invalid_Input}
	vertex_count := len(mesh.vertex_x)
	triangle_count := len(mesh.triangle_ids)
	if u64(vertex_count) > limits.max_vertices {
		return {}, .Vertex_Limit
	}
	if u64(triangle_count) > limits.max_triangles {
		return {}, .Triangle_Limit
	}
	if triangle_count > max(int)/4 {
		return {}, .Arithmetic
	}
	maximum_edge_count := u64(triangle_count)*3
	maximum_issue_count := u64(triangle_count)*4
	maximum_reference_count := u64(triangle_count)*4
	if maximum_edge_count > limits.max_edges {
		return {}, .Edge_Limit
	}
	if maximum_issue_count > limits.max_issues ||
	   maximum_reference_count > limits.max_issue_triangle_refs {
		return {}, .Issue_Limit
	}

	vertex_records := make(
		[]Mesh_Audit_Vertex_Record,
		vertex_count,
		allocator,
	)
	welded_indices := make([]u32, vertex_count, allocator)
	welded_records := make(
		[]Mesh_Audit_Vertex_Record,
		vertex_count,
		allocator,
	)
	edge_records := make(
		[]Mesh_Audit_Edge_Record,
		int(maximum_edge_count),
		allocator,
	)
	face_records := make(
		[]Mesh_Audit_Face_Record,
		triangle_count,
		allocator,
	)
	result: Mesh_Audit_Result
	result.issues = make(
		[]Mesh_Audit_Issue,
		int(maximum_issue_count),
		allocator,
	)
	result.triangle_ids = make(
		[]contracts.Stable_ID,
		int(maximum_reference_count),
		allocator,
	)
	if vertex_records == nil || welded_indices == nil ||
	   welded_records == nil ||
	   edge_records == nil || face_records == nil ||
	   result.issues == nil ||
	   result.triangle_ids == nil {
		delete(vertex_records, allocator)
		delete(welded_indices, allocator)
		delete(welded_records, allocator)
		delete(edge_records, allocator)
		delete(face_records, allocator)
		mesh_audit_result_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	defer delete(vertex_records, allocator)
	defer delete(welded_indices, allocator)
	defer delete(welded_records, allocator)
	defer delete(edge_records, allocator)
	defer delete(face_records, allocator)

	for &record, vertex_index in vertex_records {
		record = {
			x = mesh.vertex_x[vertex_index],
			y = mesh.vertex_y[vertex_index],
			z = mesh.vertex_z[vertex_index],
			source_index = u32(vertex_index),
		}
	}
	slice.sort_by(vertex_records, mesh_audit_vertex_less)
	welded_count: u32
	previous := Mesh_Audit_Vertex_Record{}
	for record, sorted_index in vertex_records {
		if sorted_index == 0 ||
		   record.x != previous.x ||
		   record.y != previous.y ||
		   record.z != previous.z {
			if welded_count == max(u32) {
				mesh_audit_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			welded_records[welded_count] = record
			welded_count += 1
			previous = record
		}
		welded_indices[record.source_index] = welded_count-1
	}
	result.welded_vertex_count = u64(welded_count)

	issue_write := 0
	reference_write := 0
	edge_write := 0
	face_write := 0
	for triangle_id, triangle_index in mesh.triangle_ids {
		source_indices := [3]u32{
			mesh.triangle_a[triangle_index],
			mesh.triangle_b[triangle_index],
			mesh.triangle_c[triangle_index],
		}
		vertices := [3]u32{
			welded_indices[source_indices[0]],
			welded_indices[source_indices[1]],
			welded_indices[source_indices[2]],
		}
		degenerate :=
			vertices[0] == vertices[1] ||
			vertices[1] == vertices[2] ||
			vertices[2] == vertices[0]
		if !degenerate {
			zero_area, arithmetic_ok := mesh_audit_triangle_zero_area(
				mesh,
				source_indices,
			)
			if !arithmetic_ok {
				mesh_audit_result_destroy(&result, allocator)
				return {}, .Arithmetic
			}
			degenerate = zero_area
		}
		if degenerate {
			result.issues[issue_write] = {
				code = .Degenerate_Triangle,
				triangle_offset = u64(reference_write),
				triangle_count = 1,
			}
			result.triangle_ids[reference_write] = triangle_id
			issue_write += 1
			reference_write += 1
			result.degenerate_triangle_count += 1
			continue
		}
		sorted_vertices := vertices
		mesh_audit_sort_triangle_vertices(&sorted_vertices)
		face_records[face_write] = {
			vertex_a = sorted_vertices[0],
			vertex_b = sorted_vertices[1],
			vertex_c = sorted_vertices[2],
			triangle_index = u32(triangle_index),
		}
		face_write += 1
		for local_edge in 0..<3 {
			from := vertices[local_edge]
			to := vertices[(local_edge+1)%3]
			edge_records[edge_write] = {
				vertex_a = min(from, to),
				vertex_b = max(from, to),
				triangle_index = u32(triangle_index),
				forward = from < to,
			}
			edge_write += 1
		}
	}

	faces := face_records[:face_write]
	slice.sort_by(faces, mesh_audit_face_less)
	face_start := 0
	for face_start < len(faces) {
		face_end := face_start+1
		for face_end < len(faces) &&
		    faces[face_end].vertex_a == faces[face_start].vertex_a &&
		    faces[face_end].vertex_b == faces[face_start].vertex_b &&
		    faces[face_end].vertex_c == faces[face_start].vertex_c {
			face_end += 1
		}
		if face_end-face_start > 1 {
			group := faces[face_start:face_end]
			result.issues[issue_write] = {
				code = .Duplicate_Face,
				triangle_offset = u64(reference_write),
				triangle_count = u32(len(group)),
			}
			for face in group {
				result.triangle_ids[reference_write] =
					mesh.triangle_ids[face.triangle_index]
				reference_write += 1
			}
			issue_write += 1
			result.duplicate_face_group_count += 1
		}
		face_start = face_end
	}

	edges := edge_records[:edge_write]
	slice.sort_by(edges, mesh_audit_edge_less)
	edge_start := 0
	for edge_start < len(edges) {
		edge_end := edge_start+1
		for edge_end < len(edges) &&
		    edges[edge_end].vertex_a == edges[edge_start].vertex_a &&
		    edges[edge_end].vertex_b == edges[edge_start].vertex_b {
			edge_end += 1
		}
		group := edges[edge_start:edge_end]
		code := Mesh_Issue_Code.Invalid
		switch len(group) {
		case 1:
			code = .Boundary_Edge
			result.boundary_edge_count += 1
		case 2:
			if group[0].forward == group[1].forward {
				code = .Inconsistent_Winding
				result.inconsistent_winding_count += 1
			}
		case:
			code = .Non_Manifold_Edge
			result.non_manifold_edge_count += 1
		}
		if code != .Invalid {
			vertex_a := welded_records[group[0].vertex_a]
			vertex_b := welded_records[group[0].vertex_b]
			result.issues[issue_write] = {
				code = code,
				has_edge = true,
				edge_a = mesh_audit_record_point(vertex_a),
				edge_b = mesh_audit_record_point(vertex_b),
				triangle_offset = u64(reference_write),
				triangle_count = u32(len(group)),
			}
			for edge in group {
				result.triangle_ids[reference_write] =
					mesh.triangle_ids[edge.triangle_index]
				reference_write += 1
			}
			issue_write += 1
		}
		edge_start = edge_end
	}
	result.issues = result.issues[:issue_write]
	result.triangle_ids = result.triangle_ids[:reference_write]
	for &issue, issue_index in result.issues {
		issue.stable_id = contracts.stable_id_child(
			mesh.source_root_id,
			.Mesh_Issue,
			u64(issue_index),
		)
	}
	return result, .None
}

mesh_audit_vertex_less :: proc(a, b: Mesh_Audit_Vertex_Record) -> bool {
	if a.x != b.x {return a.x < b.x}
	if a.y != b.y {return a.y < b.y}
	if a.z != b.z {return a.z < b.z}
	return a.source_index < b.source_index
}

mesh_audit_edge_less :: proc(a, b: Mesh_Audit_Edge_Record) -> bool {
	if a.vertex_a != b.vertex_a {return a.vertex_a < b.vertex_a}
	if a.vertex_b != b.vertex_b {return a.vertex_b < b.vertex_b}
	if a.triangle_index != b.triangle_index {
		return a.triangle_index < b.triangle_index
	}
	return !a.forward && b.forward
}

mesh_audit_face_less :: proc(a, b: Mesh_Audit_Face_Record) -> bool {
	if a.vertex_a != b.vertex_a {return a.vertex_a < b.vertex_a}
	if a.vertex_b != b.vertex_b {return a.vertex_b < b.vertex_b}
	if a.vertex_c != b.vertex_c {return a.vertex_c < b.vertex_c}
	return a.triangle_index < b.triangle_index
}

mesh_audit_sort_triangle_vertices :: proc(vertices: ^[3]u32) {
	if vertices[0] > vertices[1] {
		vertices[0], vertices[1] = vertices[1], vertices[0]
	}
	if vertices[1] > vertices[2] {
		vertices[1], vertices[2] = vertices[2], vertices[1]
	}
	if vertices[0] > vertices[1] {
		vertices[0], vertices[1] = vertices[1], vertices[0]
	}
}

mesh_audit_triangle_zero_area :: proc(
	mesh: Canonical_Mesh,
	indices: [3]u32,
) -> (bool, bool) {
	ax := mesh.vertex_x[indices[0]]
	ay := mesh.vertex_y[indices[0]]
	az := mesh.vertex_z[indices[0]]
	abx := mesh.vertex_x[indices[1]]-ax
	aby := mesh.vertex_y[indices[1]]-ay
	abz := mesh.vertex_z[indices[1]]-az
	acx := mesh.vertex_x[indices[2]]-ax
	acy := mesh.vertex_y[indices[2]]-ay
	acz := mesh.vertex_z[indices[2]]-az
	cross_x := aby*acz-abz*acy
	cross_y := abz*acx-abx*acz
	cross_z := abx*acy-aby*acx
	values := [9]f64{
		abx, aby, abz, acx, acy, acz, cross_x, cross_y, cross_z,
	}
	for value in values {
		if math.is_nan(value) || math.is_inf(value) {
			return false, false
		}
	}
	return cross_x == 0 && cross_y == 0 && cross_z == 0, true
}

mesh_audit_record_point :: proc(
	record: Mesh_Audit_Vertex_Record,
) -> Point_3 {
	return {
		x = contracts.Millimetres(record.x),
		y = contracts.Millimetres(record.y),
		z = contracts.Millimetres(record.z),
	}
}

mesh_audit_result_destroy :: proc(
	result: ^Mesh_Audit_Result,
	allocator := context.allocator,
) {
	delete(result.issues, allocator)
	delete(result.triangle_ids, allocator)
	result^ = {}
}
