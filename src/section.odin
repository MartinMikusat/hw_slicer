package main

import contracts "./contracts"
import geometry "./geometry"
import slicing "./slicing"

Section_Stats :: struct {
	segments: int,
	skipped:  int,
}

section_height_from_pointer :: proc(
	x: f64,
	track: UI_Rect,
	maximum: f32,
) -> f32 {
	if maximum <= 0 {return 0}
	track_x := track.x+4
	track_width := track.w-8
	fraction := min(max((x-track_x)/track_width, 0), 1)
	return f32(fraction*f64(maximum))
}

section_mesh_at_z :: proc(
	mesh: ^Mesh,
	z_mm: f32,
	vertices: ^[dynamic]Mesh_Vertex,
	transform: Mat4,
) -> Section_Stats {
	clear(vertices)
	stats: Section_Stats
	if mesh == nil || mesh.triangle_count == 0 {return stats}
	plane_z, plane_error := geometry.millimetres_to_micrometres(
		contracts.Millimetres(z_mm),
	)
	if plane_error != .None {return stats}
	for triangle in 0..<int(mesh.triangle_count) {
		base := triangle*3
		a := placement_point(transform, mesh.vertices[base+0].position)
		b := placement_point(transform, mesh.vertices[base+1].position)
		c := placement_point(transform, mesh.vertices[base+2].position)
		if (a.z > z_mm && b.z > z_mm && c.z > z_mm) ||
		   (a.z < z_mm && b.z < z_mm && c.z < z_mm) {
			continue
		}
		x := [3]f64{f64(a.x), f64(b.x), f64(c.x)}
		y := [3]f64{f64(a.y), f64(b.y), f64(c.y)}
		z := [3]f64{f64(a.z), f64(b.z), f64(c.z)}
		result, error := slicing.triangle_plane_intersect(x, y, z, plane_z)
		if error != .None {
			stats.skipped += 1
			continue
		}
		switch result.kind {
		case .Segment, .Coplanar_Edge:
			normal := Vec3{0, 0, 1}
			append(vertices, Mesh_Vertex{{f32(result.point_a.x), f32(result.point_a.y), z_mm}, normal})
			append(vertices, Mesh_Vertex{{f32(result.point_b.x), f32(result.point_b.y), z_mm}, normal})
			stats.segments += 1
		case .None, .Tangent_Vertex, .Coplanar_Face, .Degenerate_Segment:
		}
	}
	return stats
}
