package formats

import crypto_hash "core:crypto/hash"
import "core:math"
import "core:mem"

import contracts "../contracts"

Binary_STL_Limits :: struct {
	max_source_bytes: u64,
	max_triangles:    u32,
}

DEFAULT_BINARY_STL_LIMITS :: Binary_STL_Limits{
	max_source_bytes = 1_073_741_824,
	max_triangles = 10_000_000,
}

Decoded_Mesh :: struct {
	source:                contracts.Source_Asset,
	source_root_id:        contracts.Stable_ID,
	vertex_x:              []f64,
	vertex_y:              []f64,
	vertex_z:              []f64,
	vertex_ids:            []contracts.Stable_ID,
	triangle_a:            []u32,
	triangle_b:            []u32,
	triangle_c:            []u32,
	triangle_ids:          []contracts.Stable_ID,
	source_record_offsets: []u64,
}

Decode_Error :: enum u8 {
	None,
	Truncated,
	Empty,
	Source_Limit,
	Triangle_Limit,
	Length_Mismatch,
	Index_Overflow,
	Non_Finite,
	Allocation_Failed,
	Invalid_Syntax,
}

binary_stl_decode :: proc(
	bytes: []u8,
	source_units: contracts.Source_Units,
	limits := DEFAULT_BINARY_STL_LIMITS,
	allocator := context.allocator,
) -> (Decoded_Mesh, Decode_Error) {
	if len(bytes) < 84 {return {}, .Truncated}
	if u64(len(bytes)) > limits.max_source_bytes {return {}, .Source_Limit}
	triangle_count := binary_stl_read_u32(bytes, 80)
	if triangle_count == 0 {return {}, .Empty}
	if triangle_count > limits.max_triangles {return {}, .Triangle_Limit}
	expected_size := u64(84)+u64(triangle_count)*50
	if expected_size != u64(len(bytes)) {return {}, .Length_Mismatch}
	if triangle_count > max(u32)/3 {return {}, .Index_Overflow}

	mesh: Decoded_Mesh
	mesh.source = {
		byte_count = u64(len(bytes)),
		format = .Binary_STL,
		units = source_units,
	}
	_ = crypto_hash.hash_bytes_to_buffer(
		.SHA256,
		bytes,
		mesh.source.content_hash[:],
	)
	mesh.source_root_id = contracts.stable_id_root(
		mesh.source.content_hash,
		.Source,
	)

	vertex_count := int(triangle_count)*3
	if !decoded_mesh_allocate(
		&mesh,
		vertex_count,
		int(triangle_count),
		allocator,
	) {
		decoded_mesh_destroy(&mesh, allocator)
		return {}, .Allocation_Failed
	}

	cursor := 84
	for triangle_index in 0..<int(triangle_count) {
		for float_index in 0..<12 {
			value := binary_stl_read_f32(bytes, cursor+float_index*4)
			if math.is_nan(value) || math.is_inf(value) {
				decoded_mesh_destroy(&mesh, allocator)
				return {}, .Non_Finite
			}
		}
		triangle_id := contracts.stable_id_child(
			mesh.source_root_id,
			.Triangle,
			u64(triangle_index),
		)
		mesh.triangle_ids[triangle_index] = triangle_id
		mesh.source_record_offsets[triangle_index] = u64(cursor)
		first_vertex := triangle_index*3
		mesh.triangle_a[triangle_index] = u32(first_vertex)
		mesh.triangle_b[triangle_index] = u32(first_vertex+1)
		mesh.triangle_c[triangle_index] = u32(first_vertex+2)
		for local_vertex in 0..<3 {
			source_offset := cursor+12+local_vertex*12
			vertex_index := first_vertex+local_vertex
			x := f64(binary_stl_read_f32(bytes, source_offset))
			y := f64(binary_stl_read_f32(bytes, source_offset+4))
			z := f64(binary_stl_read_f32(bytes, source_offset+8))
			if x == 0 {x = 0}
			if y == 0 {y = 0}
			if z == 0 {z = 0}
			mesh.vertex_x[vertex_index] = x
			mesh.vertex_y[vertex_index] = y
			mesh.vertex_z[vertex_index] = z
			mesh.vertex_ids[vertex_index] = contracts.stable_id_child(
				triangle_id,
				.Vertex,
				u64(local_vertex),
			)
		}
		cursor += 50
	}
	return mesh, .None
}

decoded_mesh_allocate :: proc(
	mesh: ^Decoded_Mesh,
	vertex_count: int,
	triangle_count: int,
	allocator: mem.Allocator,
) -> bool {
	mesh.vertex_x = make([]f64, vertex_count, allocator)
	mesh.vertex_y = make([]f64, vertex_count, allocator)
	mesh.vertex_z = make([]f64, vertex_count, allocator)
	mesh.vertex_ids = make([]contracts.Stable_ID, vertex_count, allocator)
	mesh.triangle_a = make([]u32, triangle_count, allocator)
	mesh.triangle_b = make([]u32, triangle_count, allocator)
	mesh.triangle_c = make([]u32, triangle_count, allocator)
	mesh.triangle_ids = make(
		[]contracts.Stable_ID,
		triangle_count,
		allocator,
	)
	mesh.source_record_offsets = make([]u64, triangle_count, allocator)
	return mesh.vertex_x != nil && mesh.vertex_y != nil &&
		mesh.vertex_z != nil && mesh.vertex_ids != nil &&
		mesh.triangle_a != nil && mesh.triangle_b != nil &&
		mesh.triangle_c != nil && mesh.triangle_ids != nil &&
		mesh.source_record_offsets != nil
}

decoded_mesh_destroy :: proc(
	mesh: ^Decoded_Mesh,
	allocator := context.allocator,
) {
	delete(mesh.vertex_x, allocator)
	delete(mesh.vertex_y, allocator)
	delete(mesh.vertex_z, allocator)
	delete(mesh.vertex_ids, allocator)
	delete(mesh.triangle_a, allocator)
	delete(mesh.triangle_b, allocator)
	delete(mesh.triangle_c, allocator)
	delete(mesh.triangle_ids, allocator)
	delete(mesh.source_record_offsets, allocator)
	mesh^ = {}
}

binary_stl_read_u32 :: proc(bytes: []u8, offset: int) -> u32 {
	return u32(bytes[offset]) |
		u32(bytes[offset+1])<<8 |
		u32(bytes[offset+2])<<16 |
		u32(bytes[offset+3])<<24
}

binary_stl_read_f32 :: proc(bytes: []u8, offset: int) -> f32 {
	return transmute(f32)binary_stl_read_u32(bytes, offset)
}
