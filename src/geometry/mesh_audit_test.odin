package geometry

import "core:testing"

import contracts "../contracts"

@(test)
mesh_audit_welds_duplicate_vertices_in_closed_tetrahedron_test :: proc(
	t: ^testing.T,
) {
	points := [?]Point_3{
		{0, 0, 0}, {0, 10, 0}, {10, 0, 0},
		{0, 0, 0}, {10, 0, 0}, {0, 0, 10},
		{0, 0, 0}, {0, 0, 10}, {0, 10, 0},
		{10, 0, 0}, {0, 10, 0}, {0, 0, 10},
	}
	triangles := [?][3]u32{
		{0, 1, 2},
		{3, 4, 5},
		{6, 7, 8},
		{9, 10, 11},
	}
	mesh := mesh_audit_test_mesh(points[:], triangles[:])
	defer canonical_mesh_destroy(&mesh)
	result, error := mesh_audit(mesh)
	defer mesh_audit_result_destroy(&result)
	testing.expect_value(t, error, Mesh_Audit_Error.None)
	testing.expect_value(t, result.welded_vertex_count, u64(4))
	testing.expect_value(t, len(result.issues), 0)
	testing.expect_value(t, result.boundary_edge_count, u64(0))
	testing.expect_value(t, result.non_manifold_edge_count, u64(0))
	testing.expect_value(t, result.inconsistent_winding_count, u64(0))
}

@(test)
mesh_audit_reports_boundary_edges_with_triangle_provenance_test :: proc(
	t: ^testing.T,
) {
	points := [?]Point_3{{0, 0, 0}, {10, 0, 0}, {0, 10, 0}}
	triangles := [?][3]u32{{0, 1, 2}}
	mesh := mesh_audit_test_mesh(points[:], triangles[:])
	defer canonical_mesh_destroy(&mesh)
	result, error := mesh_audit(mesh)
	defer mesh_audit_result_destroy(&result)
	testing.expect_value(t, error, Mesh_Audit_Error.None)
	testing.expect_value(t, result.boundary_edge_count, u64(3))
	testing.expect_value(t, len(result.issues), 3)
	testing.expect_value(t, len(result.triangle_ids), 3)
	for issue in result.issues {
		testing.expect_value(t, issue.code, Mesh_Issue_Code.Boundary_Edge)
		testing.expect(t, issue.has_edge)
		testing.expect_value(t, issue.triangle_count, u32(1))
	}
	mesh_hash, mesh_hash_ok := canonical_mesh_hash(mesh)
	testing.expect(t, mesh_hash_ok)
	audit_hash, audit_hash_ok := mesh_audit_hash(mesh_hash, result)
	testing.expect(t, audit_hash_ok)
	expected_hash := contracts.Content_Hash{
		0x58, 0x78, 0xcc, 0x1e, 0xb1, 0x0a, 0x5d, 0x40,
		0x36, 0x18, 0xa7, 0x73, 0x88, 0xb7, 0xc4, 0x27,
		0xee, 0xb3, 0x5b, 0x00, 0xe7, 0xb1, 0x4d, 0x69,
		0x47, 0x2e, 0xb0, 0x34, 0xde, 0x0e, 0x59, 0x78,
	}
	testing.expect_value(t, audit_hash, expected_hash)
}

@(test)
mesh_audit_distinguishes_winding_and_non_manifold_edges_test :: proc(
	t: ^testing.T,
) {
	points := [?]Point_3{
		{0, 0, 0},
		{10, 0, 0},
		{0, 10, 0},
		{0, 0, 10},
		{0, -10, 0},
	}
	winding_triangles := [?][3]u32{{0, 1, 2}, {0, 1, 3}}
	winding_mesh :=
		mesh_audit_test_mesh(points[:4], winding_triangles[:])
	defer canonical_mesh_destroy(&winding_mesh)
	winding, winding_error := mesh_audit(winding_mesh)
	defer mesh_audit_result_destroy(&winding)
	testing.expect_value(t, winding_error, Mesh_Audit_Error.None)
	testing.expect_value(t, winding.inconsistent_winding_count, u64(1))
	testing.expect_value(t, winding.non_manifold_edge_count, u64(0))
	testing.expect_value(t, winding.boundary_edge_count, u64(4))

	non_manifold_triangles :=
		[?][3]u32{{0, 1, 2}, {1, 0, 3}, {0, 1, 4}}
	non_manifold_mesh :=
		mesh_audit_test_mesh(points[:], non_manifold_triangles[:])
	defer canonical_mesh_destroy(&non_manifold_mesh)
	non_manifold, non_manifold_error := mesh_audit(non_manifold_mesh)
	defer mesh_audit_result_destroy(&non_manifold)
	testing.expect_value(
		t,
		non_manifold_error,
		Mesh_Audit_Error.None,
	)
	testing.expect_value(
		t,
		non_manifold.non_manifold_edge_count,
		u64(1),
	)
	testing.expect_value(
		t,
		non_manifold.inconsistent_winding_count,
		u64(0),
	)
	testing.expect_value(t, non_manifold.boundary_edge_count, u64(6))
}

@(test)
mesh_audit_reports_duplicate_faces_independently_from_edge_winding_test :: proc(
	t: ^testing.T,
) {
	points := [?]Point_3{{0, 0, 0}, {10, 0, 0}, {0, 10, 0}}
	triangles := [?][3]u32{{0, 1, 2}, {2, 1, 0}}
	mesh := mesh_audit_test_mesh(points[:], triangles[:])
	defer canonical_mesh_destroy(&mesh)
	result, error := mesh_audit(mesh)
	defer mesh_audit_result_destroy(&result)
	testing.expect_value(t, error, Mesh_Audit_Error.None)
	testing.expect_value(t, result.duplicate_face_group_count, u64(1))
	testing.expect_value(t, result.boundary_edge_count, u64(0))
	testing.expect_value(t, result.non_manifold_edge_count, u64(0))
	testing.expect_value(t, result.inconsistent_winding_count, u64(0))
	testing.expect_value(t, len(result.issues), 1)
	testing.expect_value(
		t,
		result.issues[0].code,
		Mesh_Issue_Code.Duplicate_Face,
	)
	testing.expect_value(t, result.issues[0].triangle_count, u32(2))
	testing.expect_value(t, len(result.triangle_ids), 2)
}

@(test)
mesh_audit_reports_degenerate_triangles_and_enforces_limits_test :: proc(
	t: ^testing.T,
) {
	points := [?]Point_3{{0, 0, 0}, {5, 0, 0}, {10, 0, 0}}
	triangles := [?][3]u32{{0, 1, 2}}
	mesh := mesh_audit_test_mesh(points[:], triangles[:])
	defer canonical_mesh_destroy(&mesh)
	result, error := mesh_audit(mesh)
	defer mesh_audit_result_destroy(&result)
	testing.expect_value(t, error, Mesh_Audit_Error.None)
	testing.expect_value(t, result.degenerate_triangle_count, u64(1))
	testing.expect_value(t, result.boundary_edge_count, u64(0))
	testing.expect_value(t, len(result.issues), 1)
	testing.expect_value(
		t,
		result.issues[0].code,
		Mesh_Issue_Code.Degenerate_Triangle,
	)
	testing.expect_value(t, result.triangle_ids[0], mesh.triangle_ids[0])

	_, limit_error := mesh_audit(
		mesh,
		{
			max_vertices = 2,
			max_triangles = 1,
			max_edges = 3,
			max_issues = 4,
			max_issue_triangle_refs = 4,
		},
	)
	testing.expect_value(t, limit_error, Mesh_Audit_Error.Vertex_Limit)
}

mesh_audit_test_mesh :: proc(
	points: []Point_3,
	triangles: [][3]u32,
) -> Canonical_Mesh {
	mesh: Canonical_Mesh
	mesh.source = {
		byte_count = 1,
		format = .OBJ,
		units = .Millimetres,
	}
	mesh.coordinate_units = .Millimetres
	mesh.source_root_id = 1
	mesh.vertex_x = make([]f64, len(points))
	mesh.vertex_y = make([]f64, len(points))
	mesh.vertex_z = make([]f64, len(points))
	mesh.vertex_ids = make([]contracts.Stable_ID, len(points))
	mesh.triangle_a = make([]u32, len(triangles))
	mesh.triangle_b = make([]u32, len(triangles))
	mesh.triangle_c = make([]u32, len(triangles))
	mesh.triangle_ids = make([]contracts.Stable_ID, len(triangles))
	mesh.source_record_offsets = make([]u64, len(triangles))
	for point, vertex_index in points {
		x := f64(point.x)
		y := f64(point.y)
		z := f64(point.z)
		mesh.vertex_x[vertex_index] = x
		mesh.vertex_y[vertex_index] = y
		mesh.vertex_z[vertex_index] = z
		mesh.vertex_ids[vertex_index] =
			contracts.Stable_ID(vertex_index+1)
		if vertex_index == 0 {
			mesh.bounds = {minimum = point, maximum = point}
		} else {
			mesh.bounds.minimum.x = contracts.Millimetres(
				min(f64(mesh.bounds.minimum.x), x),
			)
			mesh.bounds.minimum.y = contracts.Millimetres(
				min(f64(mesh.bounds.minimum.y), y),
			)
			mesh.bounds.minimum.z = contracts.Millimetres(
				min(f64(mesh.bounds.minimum.z), z),
			)
			mesh.bounds.maximum.x = contracts.Millimetres(
				max(f64(mesh.bounds.maximum.x), x),
			)
			mesh.bounds.maximum.y = contracts.Millimetres(
				max(f64(mesh.bounds.maximum.y), y),
			)
			mesh.bounds.maximum.z = contracts.Millimetres(
				max(f64(mesh.bounds.maximum.z), z),
			)
		}
	}
	for triangle, triangle_index in triangles {
		mesh.triangle_a[triangle_index] = triangle[0]
		mesh.triangle_b[triangle_index] = triangle[1]
		mesh.triangle_c[triangle_index] = triangle[2]
		mesh.triangle_ids[triangle_index] =
			contracts.Stable_ID(100+triangle_index)
		mesh.source_record_offsets[triangle_index] =
			u64(triangle_index)
	}
	return mesh
}
