package main

import "core:math"

Model_Placement :: struct {
	transform: Mat4,
	bounds: Mesh_Bounds,
}

placement_point :: proc(m: Mat4, p: Vec3) -> Vec3 {
	return {m[0]*p.x+m[4]*p.y+m[8]*p.z+m[12],
	        m[1]*p.x+m[5]*p.y+m[9]*p.z+m[13],
	        m[2]*p.x+m[6]*p.y+m[10]*p.z+m[14]}
}

placement_on_bed :: proc(mesh: ^Mesh, rotation: Mat4) -> Model_Placement {
	bounds := Mesh_Bounds{{max(f32), max(f32), max(f32)}, {-max(f32), -max(f32), -max(f32)}}
	for vertex in mesh.vertices {
		p := placement_point(rotation, vertex.position)
		bounds.minimum = {min(bounds.minimum.x,p.x), min(bounds.minimum.y,p.y), min(bounds.minimum.z,p.z)}
		bounds.maximum = {max(bounds.maximum.x,p.x), max(bounds.maximum.y,p.y), max(bounds.maximum.z,p.z)}
	}
	center := mesh_center(bounds)
	offset := Vec3{-center.x, -center.y, -bounds.minimum.z}
	return {mat4_mul(mat4_translation(offset), rotation),
	        {vec3_add(bounds.minimum,offset), vec3_add(bounds.maximum,offset)}}
}

placement_face :: proc(mesh: ^Mesh, triangle: int) -> (Mat4, bool) {
	if triangle < 0 || triangle >= int(mesh.triangle_count) {return {}, false}
	a := mesh.vertices[triangle*3].position
	b := mesh.vertices[triangle*3+1].position
	c := mesh.vertices[triangle*3+2].position
	n := vec3_cross(vec3_sub(b,a), vec3_sub(c,a))
	if vec3_length(n) <= 0.000001 {return {}, false}
	n = vec3_normalize(n)
	minimum, maximum := f32(0), f32(0)
	for vertex in mesh.vertices {
		d := vec3_dot(n,vec3_sub(vertex.position,a))
		minimum = min(minimum,d)
		maximum = max(maximum,d)
	}
	tolerance := max(f32(0.00001),vec3_length(mesh_size(mesh.bounds))*0.000001)
	if minimum < -tolerance && maximum > tolerance {return {}, false}
	if maximum > tolerance {n = vec3_mul(n,-1)}
	z := vec3_mul(n,-1)
	reference := Vec3{1,0,0}
	if math.abs(z.x) > 0.9 {reference = {0,1,0}}
	y := vec3_normalize(vec3_cross(z,reference))
	x := vec3_cross(y,z)
	return {x.x,y.x,z.x,0, x.y,y.y,z.y,0, x.z,y.z,z.z,0, 0,0,0,1}, true
}

placement_pick :: proc(mesh: ^Mesh, placement: Model_Placement, camera: Camera, viewport: UI_Rect, px, py: f64) -> int {
	eye := app_camera_eye(camera)
	forward := vec3_normalize(vec3_sub(camera.target,eye))
	right := vec3_normalize(vec3_cross(forward,{0,0,1}))
	up := vec3_cross(right,forward)
	h := f32(math.tan(0.78/2.0))
	x := f32(2*(px-viewport.x)/viewport.w-1)*h*f32(viewport.w/viewport.h)
	y := f32(1-2*(py-viewport.y)/viewport.h)*h
	direction := vec3_normalize(vec3_add(forward,vec3_add(vec3_mul(right,x),vec3_mul(up,y))))
	nearest := max(f32)
	selected := -1
	for triangle in 0..<int(mesh.triangle_count) {
		a := placement_point(placement.transform,mesh.vertices[triangle*3].position)
		b := placement_point(placement.transform,mesh.vertices[triangle*3+1].position)
		c := placement_point(placement.transform,mesh.vertices[triangle*3+2].position)
		e1, e2 := vec3_sub(b,a), vec3_sub(c,a)
		p := vec3_cross(direction,e2)
		det := vec3_dot(e1,p)
		if math.abs(det) < 0.00000001 {continue}
		t := vec3_sub(eye,a)
		u := vec3_dot(t,p)/det
		if u < 0 || u > 1 {continue}
		q := vec3_cross(t,e1)
		v := vec3_dot(direction,q)/det
		if v < 0 || u+v > 1 {continue}
		distance := vec3_dot(e2,q)/det
		if distance > 0 && distance < nearest {nearest = distance; selected = triangle}
	}
	return selected
}
