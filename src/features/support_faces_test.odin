package features

import "core:testing"

import contracts "../contracts"
import geometry "../geometry"
import polygon "../polygon"
import profiles "../profiles"

@(test)
support_faces_classify_winding_and_overhang_threshold_test :: proc(
	t: ^testing.T,
) {
	mesh := support_face_test_mesh()
	defer geometry.canonical_mesh_destroy(&mesh)
	process := support_face_test_process(45_000)
	result, error := support_faces_classify(mesh, process)
	defer support_face_result_destroy(&result)
	testing.expect_value(t, error, Support_Face_Error.None)
	testing.expect_value(t, len(result.faces), 6)
	testing.expect_value(t, result.overhang_count, u64(2))
	testing.expect_value(t, result.within_limit_count, u64(1))
	testing.expect_value(t, result.upward_or_vertical_count, u64(2))
	testing.expect_value(t, result.degenerate_count, u64(1))
	testing.expect_value(t, len(result.points), 6)
	expected_kinds := []Support_Face_Kind{
		.Downward_Overhang,
		.Upward_Or_Vertical,
		.Upward_Or_Vertical,
		.Downward_Within_Limit,
		.Downward_Overhang,
		.Degenerate,
	}
	for kind, face_index in expected_kinds {
		testing.expect_value(t, result.faces[face_index].kind, kind)
	}
	first := result.faces[0]
	testing.expect_value(t, first.normal_z, f64(-1))
	testing.expect_value(t, first.downward_z_squared, f64(1))
	testing.expect_value(
		t,
		first.minimum_z,
		contracts.Micrometres(1_000),
	)
	testing.expect_value(
		t,
		first.maximum_z,
		contracts.Micrometres(1_000),
	)
	testing.expect_value(t, first.point_count, u8(3))
	testing.expect_value(t, first.projected_area_2, i128(1_000_000))
	mesh_hash, mesh_hash_ok := geometry.canonical_mesh_hash(mesh)
	testing.expect(t, mesh_hash_ok)
	process_hash: contracts.Content_Hash
	process_hash[0] = 0x50
	hash, hash_ok := support_face_result_hash(
		mesh_hash,
		process_hash,
		mesh,
		process,
		result,
	)
	testing.expect(t, hash_ok)
	expected_hash := contracts.Content_Hash{
		0x2e, 0x99, 0x0c, 0xe0, 0xe0, 0xf0, 0xd7, 0xa5,
		0x57, 0xfa, 0x53, 0x8f, 0xa3, 0xce, 0xf1, 0xb3,
		0x65, 0x8f, 0xe7, 0xe6, 0x38, 0x1c, 0x75, 0x99,
		0xac, 0xcb, 0x6b, 0xa2, 0x8a, 0xaf, 0x39, 0x45,
	}
	testing.expect_value(t, hash, expected_hash)
}

@(test)
support_faces_apply_a_stricter_surface_angle_test :: proc(t: ^testing.T) {
	mesh := support_face_test_mesh()
	defer geometry.canonical_mesh_destroy(&mesh)
	result, error := support_faces_classify(
		mesh,
		support_face_test_process(80_000),
	)
	defer support_face_result_destroy(&result)
	testing.expect_value(t, error, Support_Face_Error.None)
	testing.expect_value(t, result.overhang_count, u64(1))
	testing.expect_value(t, result.within_limit_count, u64(2))
	testing.expect_value(
		t,
		result.faces[4].kind,
		Support_Face_Kind.Downward_Within_Limit,
	)
}

@(test)
support_face_hash_rejects_mutated_normals_test :: proc(t: ^testing.T) {
	mesh := support_face_test_mesh()
	defer geometry.canonical_mesh_destroy(&mesh)
	process := support_face_test_process(45_000)
	result, error := support_faces_classify(mesh, process)
	defer support_face_result_destroy(&result)
	testing.expect_value(t, error, Support_Face_Error.None)
	if len(result.faces) == 0 {return}
	result.faces[0].normal_z += 1
	mesh_hash, mesh_hash_ok := geometry.canonical_mesh_hash(mesh)
	testing.expect(t, mesh_hash_ok)
	_, hash_ok := support_face_result_hash(
		mesh_hash,
		{},
		mesh,
		process,
		result,
	)
	testing.expect(t, !hash_ok)
}

@(test)
support_face_projections_are_positive_and_canonical_test :: proc(
	t: ^testing.T,
) {
	mesh := support_face_test_mesh()
	defer geometry.canonical_mesh_destroy(&mesh)
	result, error := support_faces_classify(
		mesh,
		support_face_test_process(45_000),
	)
	defer support_face_result_destroy(&result)
	testing.expect_value(t, error, Support_Face_Error.None)
	for face in result.faces {
		if face.kind != .Downward_Overhang {continue}
		start := int(face.point_offset)
		end := start+int(face.point_count)
		points := result.points[start:end]
		testing.expect_value(
			t,
			polygon.polygon_minimum_rotation(points),
			0,
		)
		testing.expect(t, face.projected_area_2 > 0)
	}
}

support_face_test_process :: proc(
	angle: profiles.Angle_Millidegrees,
) -> profiles.Resolved_Process_Profile {
	return {
		source = {
			support_demand = .Mesh_And_Layer_Projection,
			support_mode = .Everywhere,
			support_overhang_angle = angle,
			support_clearance_xy = 300,
			support_clearance_z = 200,
			support_expansion = 200,
			support_density = 150_000,
			support_pattern = .Rectilinear,
			support_interface_layers = 3,
			support_interface_spacing = 250,
		},
	}
}

support_face_test_mesh :: proc() -> geometry.Canonical_Mesh {
	positions := [6][3][3]f64{
		{{0, 0, 1}, {0, 1, 1}, {1, 0, 1}},
		{{0, 0, 2}, {1, 0, 2}, {0, 1, 2}},
		{{0, 0, 0}, {0, 1, 0}, {0, 0, 1}},
		{{0, 0, 3}, {0, 1, 3}, {1, 0, -8}},
		{{0, 0, 4}, {0, 1, 4}, {1, 0, 3.5}},
		{{0, 0, 5}, {0, 0, 5}, {1, 0, 5}},
	}
	mesh := geometry.Canonical_Mesh{
		source = {
			byte_count = 1,
			format = .Binary_STL,
			units = .Millimetres,
		},
		coordinate_units = .Millimetres,
		source_root_id = 1,
		bounds = {
			minimum = {0, 0, -8},
			maximum = {1, 1, 5},
		},
	}
	vertex_count := len(positions)*3
	mesh.vertex_x = make([]f64, vertex_count)
	mesh.vertex_y = make([]f64, vertex_count)
	mesh.vertex_z = make([]f64, vertex_count)
	mesh.vertex_ids = make([]contracts.Stable_ID, vertex_count)
	mesh.triangle_a = make([]u32, len(positions))
	mesh.triangle_b = make([]u32, len(positions))
	mesh.triangle_c = make([]u32, len(positions))
	mesh.triangle_ids = make([]contracts.Stable_ID, len(positions))
	mesh.source_record_offsets = make([]u64, len(positions))
	for triangle, triangle_index in positions {
		vertex_offset := triangle_index*3
		for point, local_index in triangle {
			vertex_index := vertex_offset+local_index
			mesh.vertex_x[vertex_index] = point[0]
			mesh.vertex_y[vertex_index] = point[1]
			mesh.vertex_z[vertex_index] = point[2]
			mesh.vertex_ids[vertex_index] =
				contracts.Stable_ID(vertex_index+1)
		}
		mesh.triangle_a[triangle_index] = u32(vertex_offset)
		mesh.triangle_b[triangle_index] = u32(vertex_offset+1)
		mesh.triangle_c[triangle_index] = u32(vertex_offset+2)
		mesh.triangle_ids[triangle_index] =
			contracts.Stable_ID(100+triangle_index)
		mesh.source_record_offsets[triangle_index] = u64(triangle_index)
	}
	return mesh
}
