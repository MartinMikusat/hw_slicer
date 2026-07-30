package main

import "core:fmt"
import "core:strings"

import formats "./formats"

Mesh_Vertex :: struct {
	position: Vec3,
	normal:   Vec3,
}

Mesh_Bounds :: struct {
	minimum: Vec3,
	maximum: Vec3,
}

Mesh :: struct {
	vertices:       [dynamic]Mesh_Vertex,
	bounds:         Mesh_Bounds,
	triangle_count: u32,
	source_path:    string,
}

Mesh_Error :: enum {
	None,
	Read_Failed,
	Source_Limit,
	Truncated,
	Invalid_Triangle_Count,
	Unsupported_Format,
	Allocation_Failed,
}

mesh_destroy :: proc(mesh: ^Mesh) {
	delete(mesh.vertices)
	delete(mesh.source_path)
	mesh^ = {}
}

mesh_size :: proc(bounds: Mesh_Bounds) -> Vec3 {
	return vec3_sub(bounds.maximum, bounds.minimum)
}

mesh_center :: proc(bounds: Mesh_Bounds) -> Vec3 {
	return vec3_mul(vec3_add(bounds.minimum, bounds.maximum), 0.5)
}

mesh_load_stl :: proc(
	path: string,
	allocator := context.allocator,
) -> (Mesh, Mesh_Error) {
	bytes, read_error := formats.source_file_read_bounded(
		path,
		84,
		formats.DEFAULT_BINARY_STL_LIMITS.max_source_bytes,
		allocator,
	)
	switch read_error {
	case .None:
	case .Size_Limit:
		return {}, .Source_Limit
	case .Allocation_Failed:
		return {}, .Allocation_Failed
	case .Open_Failed, .Read_Failed, .Changed_During_Read:
		return {}, .Read_Failed
	}
	defer delete(bytes, allocator)
	mesh, error := mesh_parse_binary_stl(bytes, allocator)
	if error != .None {return {}, error}
	mesh.source_path = strings.clone(path, allocator)
	return mesh, .None
}

mesh_parse_binary_stl :: proc(
	bytes: []u8,
	allocator := context.allocator,
) -> (Mesh, Mesh_Error) {
	if len(bytes) < 84 {return {}, .Truncated}
	triangle_count := read_u32_le(bytes, 80)
	if triangle_count == 0 {return {}, .Invalid_Triangle_Count}
	if uint(triangle_count) > (uint(max(int))-84)/50 {
		return {}, .Invalid_Triangle_Count
	}
	expected_size := 84+int(triangle_count)*50
	if len(bytes) != expected_size {
		return {}, .Unsupported_Format
	}
	if uint(triangle_count) > uint(max(int))/3 {
		return {}, .Invalid_Triangle_Count
	}

	mesh := Mesh{
		bounds = {
			minimum = {3.402823e38, 3.402823e38, 3.402823e38},
			maximum = {-3.402823e38, -3.402823e38, -3.402823e38},
		},
		triangle_count = triangle_count,
	}
	mesh.vertices, _ = make([dynamic]Mesh_Vertex, 0, int(triangle_count)*3, allocator)
	if mesh.vertices == nil {return {}, .Allocation_Failed}

	cursor := 84
	for _ in 0..<triangle_count {
		stored_normal := Vec3{
			read_f32_le(bytes, cursor+0),
			read_f32_le(bytes, cursor+4),
			read_f32_le(bytes, cursor+8),
		}
		positions := [3]Vec3{
			{
				read_f32_le(bytes, cursor+12),
				read_f32_le(bytes, cursor+16),
				read_f32_le(bytes, cursor+20),
			},
			{
				read_f32_le(bytes, cursor+24),
				read_f32_le(bytes, cursor+28),
				read_f32_le(bytes, cursor+32),
			},
			{
				read_f32_le(bytes, cursor+36),
				read_f32_le(bytes, cursor+40),
				read_f32_le(bytes, cursor+44),
			},
		}
		normal := stored_normal
		if vec3_length(normal) <= 0.000001 {
			normal = vec3_cross(
				vec3_sub(positions[1], positions[0]),
				vec3_sub(positions[2], positions[0]),
			)
		}
		normal = vec3_normalize(normal)
		for position in positions {
			append(&mesh.vertices, Mesh_Vertex{position, normal})
			mesh.bounds.minimum.x = min(mesh.bounds.minimum.x, position.x)
			mesh.bounds.minimum.y = min(mesh.bounds.minimum.y, position.y)
			mesh.bounds.minimum.z = min(mesh.bounds.minimum.z, position.z)
			mesh.bounds.maximum.x = max(mesh.bounds.maximum.x, position.x)
			mesh.bounds.maximum.y = max(mesh.bounds.maximum.y, position.y)
			mesh.bounds.maximum.z = max(mesh.bounds.maximum.z, position.z)
		}
		cursor += 50
	}
	return mesh, .None
}

mesh_error_text :: proc(error: Mesh_Error) -> string {
	switch error {
	case .None:
		return "none"
	case .Read_Failed:
		return "the file could not be read"
	case .Source_Limit:
		return "the file size is outside the source limit"
	case .Truncated:
		return "the STL header is incomplete"
	case .Invalid_Triangle_Count:
		return "the STL triangle count is invalid"
	case .Unsupported_Format:
		return "the file is not an exact binary STL payload"
	case .Allocation_Failed:
		return "memory allocation failed while loading the mesh"
	}
	return fmt.tprintf("unknown mesh error %d", int(error))
}

read_u32_le :: proc(bytes: []u8, offset: int) -> u32 {
	return u32(bytes[offset+0]) |
		u32(bytes[offset+1])<<8 |
		u32(bytes[offset+2])<<16 |
		u32(bytes[offset+3])<<24
}

read_f32_le :: proc(bytes: []u8, offset: int) -> f32 {
	bits := read_u32_le(bytes, offset)
	return transmute(f32)bits
}
