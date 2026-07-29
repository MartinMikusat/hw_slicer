package main

import "core:math"

Vec2 :: struct {x, y: f32}
Vec3 :: struct {x, y, z: f32}
Vec4 :: struct {x, y, z, w: f32}
Mat4 :: [16]f32

vec3_add :: proc(a, b: Vec3) -> Vec3 {
	return {a.x+b.x, a.y+b.y, a.z+b.z}
}

vec3_sub :: proc(a, b: Vec3) -> Vec3 {
	return {a.x-b.x, a.y-b.y, a.z-b.z}
}

vec3_mul :: proc(a: Vec3, scale: f32) -> Vec3 {
	return {a.x*scale, a.y*scale, a.z*scale}
}

vec3_dot :: proc(a, b: Vec3) -> f32 {
	return a.x*b.x + a.y*b.y + a.z*b.z
}

vec3_cross :: proc(a, b: Vec3) -> Vec3 {
	return {
		a.y*b.z-a.z*b.y,
		a.z*b.x-a.x*b.z,
		a.x*b.y-a.y*b.x,
	}
}

vec3_length :: proc(a: Vec3) -> f32 {
	return math.sqrt(vec3_dot(a, a))
}

vec3_normalize :: proc(a: Vec3) -> Vec3 {
	length := vec3_length(a)
	if length <= 0.000001 {return {0, 0, 1}}
	return vec3_mul(a, 1.0/length)
}

mat4_identity :: proc() -> Mat4 {
	return {
		1, 0, 0, 0,
		0, 1, 0, 0,
		0, 0, 1, 0,
		0, 0, 0, 1,
	}
}

mat4_translation :: proc(value: Vec3) -> Mat4 {
	result := mat4_identity()
	result[12] = value.x
	result[13] = value.y
	result[14] = value.z
	return result
}

mat4_mul :: proc(a, b: Mat4) -> Mat4 {
	result: Mat4
	for column in 0..<4 {
		for row in 0..<4 {
			value: f32
			for item in 0..<4 {
				value += a[item*4+row]*b[column*4+item]
			}
			result[column*4+row] = value
		}
	}
	return result
}

mat4_perspective :: proc(
	vertical_fov_radians, aspect, near_z, far_z: f32,
) -> Mat4 {
	y_scale := 1.0/math.tan(vertical_fov_radians*0.5)
	x_scale := y_scale/aspect
	z_scale := far_z/(near_z-far_z)
	return {
		x_scale, 0,       0,                         0,
		0,       y_scale, 0,                         0,
		0,       0,       z_scale,                  -1,
		0,       0,       near_z*far_z/(near_z-far_z), 0,
	}
}

mat4_look_at :: proc(eye, target, world_up: Vec3) -> Mat4 {
	forward := vec3_normalize(vec3_sub(target, eye))
	right := vec3_normalize(vec3_cross(forward, world_up))
	up := vec3_cross(right, forward)
	return {
		right.x,                    up.x,                    -forward.x,                   0,
		right.y,                    up.y,                    -forward.y,                   0,
		right.z,                    up.z,                    -forward.z,                   0,
		-vec3_dot(right, eye),      -vec3_dot(up, eye),       vec3_dot(forward, eye),       1,
	}
}

clamp_f32 :: proc(value, minimum, maximum: f32) -> f32 {
	return min(max(value, minimum), maximum)
}
