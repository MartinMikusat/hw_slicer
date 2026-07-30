package formats

import crypto_hash "core:crypto/hash"

import contracts "../contracts"

ASCII_STL_Limits :: struct {
	max_source_bytes: u64,
	max_triangles:    u32,
	max_token_bytes:  u32,
}

DEFAULT_ASCII_STL_LIMITS :: ASCII_STL_Limits{
	max_source_bytes = 1_073_741_824,
	max_triangles = 10_000_000,
	max_token_bytes = 256,
}

STL_Limits :: struct {
	binary: Binary_STL_Limits,
	ascii:  ASCII_STL_Limits,
}

DEFAULT_STL_LIMITS :: STL_Limits{
	binary = DEFAULT_BINARY_STL_LIMITS,
	ascii = DEFAULT_ASCII_STL_LIMITS,
}

ASCII_STL_Lexer :: struct {
	bytes:           []u8,
	cursor:          int,
	max_token_bytes: u32,
}

ASCII_STL_Parse_Result :: struct {
	triangle_count: u32,
}

stl_decode :: proc(
	bytes: []u8,
	source_units: contracts.Source_Units,
	limits := DEFAULT_STL_LIMITS,
	allocator := context.allocator,
) -> (Decoded_Mesh, Decode_Error) {
	if binary_stl_length_matches(bytes) {
		return binary_stl_decode(
			bytes,
			source_units,
			limits.binary,
			allocator,
		)
	}
	return ascii_stl_decode(
		bytes,
		source_units,
		limits.ascii,
		allocator,
	)
}

binary_stl_length_matches :: proc(bytes: []u8) -> bool {
	if len(bytes) < 84 {return false}
	triangle_count := binary_stl_read_u32(bytes, 80)
	expected_size := u64(84)+u64(triangle_count)*50
	return expected_size == u64(len(bytes))
}

ascii_stl_decode :: proc(
	bytes: []u8,
	source_units: contracts.Source_Units,
	limits := DEFAULT_ASCII_STL_LIMITS,
	allocator := context.allocator,
) -> (Decoded_Mesh, Decode_Error) {
	if len(bytes) == 0 {return {}, .Empty}
	if u64(len(bytes)) > limits.max_source_bytes {
		return {}, .Source_Limit
	}
	first_pass, first_error := ascii_stl_parse(bytes, limits, nil)
	if first_error != .None {return {}, first_error}
	if first_pass.triangle_count > max(u32)/3 {
		return {}, .Index_Overflow
	}

	mesh: Decoded_Mesh
	mesh.source = {
		byte_count = u64(len(bytes)),
		format = .ASCII_STL,
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
	triangle_count := int(first_pass.triangle_count)
	if !decoded_mesh_allocate(
		&mesh,
		triangle_count*3,
		triangle_count,
		allocator,
	) {
		decoded_mesh_destroy(&mesh, allocator)
		return {}, .Allocation_Failed
	}
	second_pass, second_error := ascii_stl_parse(bytes, limits, &mesh)
	if second_error != .None ||
	   second_pass.triangle_count != first_pass.triangle_count {
		decoded_mesh_destroy(&mesh, allocator)
		if second_error != .None {return {}, second_error}
		return {}, .Length_Mismatch
	}
	return mesh, .None
}

ascii_stl_parse :: proc(
	bytes: []u8,
	limits: ASCII_STL_Limits,
	mesh: ^Decoded_Mesh,
) -> (ASCII_STL_Parse_Result, Decode_Error) {
	lexer := ASCII_STL_Lexer{
		bytes = bytes,
		max_token_bytes = limits.max_token_bytes,
	}
	if len(bytes) >= 3 &&
	   bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf {
		lexer.cursor = 3
	}
	if !ascii_stl_expect_token(&lexer, "solid") ||
	   !ascii_stl_skip_line(&lexer) {
		return {}, .Invalid_Syntax
	}

	result: ASCII_STL_Parse_Result
	for {
		token, facet_offset, token_ok := ascii_stl_next_token(&lexer)
		if !token_ok {return {}, .Invalid_Syntax}
		if token == "endsolid" {
			if !ascii_stl_skip_line(&lexer) {
				return {}, .Invalid_Syntax
			}
			ascii_stl_skip_space(&lexer)
			if lexer.cursor != len(bytes) {
				return {}, .Invalid_Syntax
			}
			if result.triangle_count == 0 {return {}, .Empty}
			return result, .None
		}
		if token != "facet" ||
		   !ascii_stl_expect_token(&lexer, "normal") {
			return {}, .Invalid_Syntax
		}
		for _ in 0..<3 {
			if _, ok := ascii_stl_next_f64(&lexer); !ok {
				return {}, .Invalid_Syntax
			}
		}
		if !ascii_stl_expect_token(&lexer, "outer") ||
		   !ascii_stl_expect_token(&lexer, "loop") {
			return {}, .Invalid_Syntax
		}
		vertices: [3][3]f64
		for vertex_index in 0..<3 {
			if !ascii_stl_expect_token(&lexer, "vertex") {
				return {}, .Invalid_Syntax
			}
			for coordinate_index in 0..<3 {
				value, value_ok := ascii_stl_next_f64(&lexer)
				if !value_ok {return {}, .Invalid_Syntax}
				if value == 0 {value = 0}
				vertices[vertex_index][coordinate_index] = value
			}
		}
		if !ascii_stl_expect_token(&lexer, "endloop") ||
		   !ascii_stl_expect_token(&lexer, "endfacet") {
			return {}, .Invalid_Syntax
		}
		if result.triangle_count >= limits.max_triangles {
			return {}, .Triangle_Limit
		}
		if mesh != nil {
			triangle_index := int(result.triangle_count)
			triangle_id := contracts.stable_id_child(
				mesh.source_root_id,
				.Triangle,
				u64(triangle_index),
			)
			mesh.triangle_ids[triangle_index] = triangle_id
			mesh.source_record_offsets[triangle_index] = u64(facet_offset)
			first_vertex := triangle_index*3
			mesh.triangle_a[triangle_index] = u32(first_vertex)
			mesh.triangle_b[triangle_index] = u32(first_vertex+1)
			mesh.triangle_c[triangle_index] = u32(first_vertex+2)
			for vertex, local_vertex in vertices {
				vertex_index := first_vertex+local_vertex
				mesh.vertex_x[vertex_index] = vertex[0]
				mesh.vertex_y[vertex_index] = vertex[1]
				mesh.vertex_z[vertex_index] = vertex[2]
				mesh.vertex_ids[vertex_index] =
					contracts.stable_id_child(
						triangle_id,
						.Vertex,
						u64(local_vertex),
					)
			}
		}
		result.triangle_count += 1
	}
}

ascii_stl_next_f64 :: proc(lexer: ^ASCII_STL_Lexer) -> (f64, bool) {
	token, _, token_ok := ascii_stl_next_token(lexer)
	if !token_ok {return 0, false}
	return three_mf_parse_f64(token)
}

ascii_stl_expect_token :: proc(
	lexer: ^ASCII_STL_Lexer,
	expected: string,
) -> bool {
	token, _, token_ok := ascii_stl_next_token(lexer)
	return token_ok && token == expected
}

ascii_stl_next_token :: proc(
	lexer: ^ASCII_STL_Lexer,
) -> (string, int, bool) {
	ascii_stl_skip_space(lexer)
	if lexer.cursor >= len(lexer.bytes) {return "", 0, false}
	start := lexer.cursor
	for lexer.cursor < len(lexer.bytes) &&
	    !ascii_stl_space(lexer.bytes[lexer.cursor]) {
		if lexer.bytes[lexer.cursor] == 0 {return "", 0, false}
		lexer.cursor += 1
	}
	token_length := lexer.cursor-start
	if token_length == 0 ||
	   u64(token_length) > u64(lexer.max_token_bytes) {
		return "", 0, false
	}
	return string(lexer.bytes[start:lexer.cursor]), start, true
}

ascii_stl_skip_line :: proc(lexer: ^ASCII_STL_Lexer) -> bool {
	for lexer.cursor < len(lexer.bytes) {
		value := lexer.bytes[lexer.cursor]
		if value == 0 {return false}
		lexer.cursor += 1
		if value == '\n' {return true}
	}
	return true
}

ascii_stl_skip_space :: proc(lexer: ^ASCII_STL_Lexer) {
	for lexer.cursor < len(lexer.bytes) &&
	    ascii_stl_space(lexer.bytes[lexer.cursor]) {
		lexer.cursor += 1
	}
}

ascii_stl_space :: proc(value: u8) -> bool {
	return value == ' ' || value == '\t' ||
		value == '\r' || value == '\n' ||
		value == 0x0b || value == 0x0c
}
