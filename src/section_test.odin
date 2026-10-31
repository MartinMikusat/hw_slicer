package main

import "core:testing"

cube_mesh_test :: proc() -> Mesh {
	mesh: Mesh
	mesh.vertices = make([dynamic]Mesh_Vertex)
	triangles := [12][3]Vec3{
		{{0, 0, 0}, {10, 0, 0}, {10, 10, 0}},
		{{0, 0, 0}, {10, 10, 0}, {0, 10, 0}},
		{{0, 0, 10}, {10, 10, 10}, {10, 0, 10}},
		{{0, 0, 10}, {0, 10, 10}, {10, 10, 10}},
		{{0, 0, 0}, {10, 0, 10}, {10, 0, 0}},
		{{0, 0, 0}, {0, 0, 10}, {10, 0, 10}},
		{{0, 10, 0}, {10, 10, 0}, {10, 10, 10}},
		{{0, 10, 0}, {10, 10, 10}, {0, 10, 10}},
		{{0, 0, 0}, {0, 10, 0}, {0, 10, 10}},
		{{0, 0, 0}, {0, 10, 10}, {0, 0, 10}},
		{{10, 0, 0}, {10, 0, 10}, {10, 10, 10}},
		{{10, 0, 0}, {10, 10, 10}, {10, 10, 0}},
	}
	for triangle in triangles {
		for position in triangle {
			append(&mesh.vertices, Mesh_Vertex{position, {0, 0, 1}})
		}
	}
	mesh.triangle_count = 12
	mesh.bounds = {minimum = {0, 0, 0}, maximum = {10, 10, 10}}
	return mesh
}

@(test)
section_mesh_at_cube_layer_returns_closed_contour_test :: proc(t: ^testing.T) {
	mesh := cube_mesh_test()
	defer mesh_destroy(&mesh)
	vertices: [dynamic]Mesh_Vertex
	defer delete(vertices)
	stats := section_mesh_at_z(&mesh, 5, &vertices, mat4_identity())
	testing.expect_value(t, stats.segments, 8)
	testing.expect_value(t, stats.skipped, 0)
	testing.expect_value(t, len(vertices), 16)
	minimum := Vec3{1000, 1000, 1000}
	maximum := Vec3{-1000, -1000, -1000}
	for vertex in vertices {
		testing.expect_value(t, vertex.position.z, f32(5))
		minimum.x = min(minimum.x, vertex.position.x)
		minimum.y = min(minimum.y, vertex.position.y)
		maximum.x = max(maximum.x, vertex.position.x)
		maximum.y = max(maximum.y, vertex.position.y)
	}
	testing.expect_value(t, minimum.x, f32(0))
	testing.expect_value(t, minimum.y, f32(0))
	testing.expect_value(t, maximum.x, f32(10))
	testing.expect_value(t, maximum.y, f32(10))
}

@(test)
section_mesh_at_z_outside_bounds_returns_no_contour_test :: proc(t: ^testing.T) {
	mesh := cube_mesh_test()
	defer mesh_destroy(&mesh)
	vertices: [dynamic]Mesh_Vertex
	defer delete(vertices)
	stats := section_mesh_at_z(&mesh, -1, &vertices, mat4_identity())
	testing.expect_value(t, stats.segments, 0)
	testing.expect_value(t, stats.skipped, 0)
	testing.expect_value(t, len(vertices), 0)
}

@(test)
section_height_pointer_clamps_to_model_height_test :: proc(t: ^testing.T) {
	track := UI_Rect{20, 306, 204, 24}
	testing.expect_value(t, section_height_from_pointer(track.x, track, 10), f32(0))
	testing.expect_value(t, section_height_from_pointer(track.x+track.w, track, 10), f32(10))
	testing.expect_value(
		t,
		section_height_from_pointer(track.x+track.w/2, track, 10),
		f32(5),
	)
	testing.expect_value(t, section_height_from_pointer(track.x, track, 0), f32(0))
}

@(test)
section_slider_drag_clears_after_lost_release_test :: proc(t: ^testing.T) {
	app = {}
	ui_initialize(&app.ui)
	defer {
		ui_destroy(&app.ui)
		app = {}
	}
	app.ui.width = 1280
	app.ui.height = 800
	app.ui.scale = 2
	app.ui.section_max = 10
	app.ui.section_z = 5
	app.ui.ui_scale = 1
	ui_build_controls(&app.ui)
	rect := ui_section_slider_rect(&app.ui)
	application_mouse(0, 0, rect.x+rect.w/2, rect.y+12, 0, 0)
	testing.expect(t, app.ui.section_dragging)
	application_mouse(1, 0, rect.x+rect.w*0.75, rect.y+12, 1, 0)
	testing.expect(t, app.ui.section_z > 5 && app.ui.section_z < 10)
	application_mouse(0, 0, 600, 400, 0, 0)
	testing.expect(t, !app.ui.section_dragging)
	testing.expect(t, app.dragging)
}

@(test)
placement_pick_face_and_section_integration_test :: proc(t: ^testing.T) {
	mesh := cube_mesh_test()
	defer mesh_destroy(&mesh)
	for &vertex in mesh.vertices {
		vertex.position.x *= 2
		vertex.position.z *= 3
	}
	mesh.bounds.maximum = {20, 10, 30}
	initial := placement_on_bed(&mesh, mat4_identity())
	camera := Camera{target = {0, 0, 15}, yaw = 0, pitch = 0, distance = 60}
	face := placement_pick(&mesh, initial, camera, {0, 0, 800, 600}, 400, 300)
	testing.expect(t, face == 10 || face == 11)
	rotation, valid := placement_face(&mesh, face)
	testing.expect(t, valid)
	placed := placement_on_bed(&mesh, rotation)
	testing.expect_value(t, placed.bounds.minimum.z, f32(0))
	testing.expect_value(t, placed.bounds.maximum.z, f32(20))
	for corner in 0..<3 {
		point := placement_point(placed.transform, mesh.vertices[face*3+corner].position)
		testing.expect_value(t, point.z, f32(0))
	}
	vertices: [dynamic]Mesh_Vertex
	defer delete(vertices)
	stats := section_mesh_at_z(&mesh, 10, &vertices, placed.transform)
	testing.expect_value(t, stats.segments, 8)
	for vertex in vertices {testing.expect_value(t, vertex.position.z, f32(10))}
	testing.expect_value(t, mesh.bounds.maximum.z, f32(30))
	for corner in 0..<3 {mesh.vertices[30+corner].position.x = 10}
	_, recessed_valid := placement_face(&mesh, 10)
	testing.expect(t, !recessed_valid)
}
