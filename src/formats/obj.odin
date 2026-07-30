package formats

import crypto_hash "core:crypto/hash"
import "core:math"
import "core:mem"
import "core:strings"

import contracts "../contracts"

OBJ_INVALID_INDEX :: u32(0xffff_ffff)

OBJ_Limits :: struct {
	max_source_bytes:  u64,
	max_positions:     u32,
	max_texcoords:     u32,
	max_normals:       u32,
	max_faces:         u32,
	max_state_records: u32,
	max_face_vertices: u32,
	max_triangles:     u32,
	max_token_bytes:   u32,
}

DEFAULT_OBJ_LIMITS :: OBJ_Limits{
	max_source_bytes = 1_073_741_824,
	max_positions = 100_000_000,
	max_texcoords = 100_000_000,
	max_normals = 100_000_000,
	max_faces = 100_000_000,
	max_state_records = 10_000_000,
	max_face_vertices = 4_096,
	max_triangles = 100_000_000,
	max_token_bytes = 4_096,
}

OBJ_Decoded_Mesh :: struct {
	mesh:                      Decoded_Mesh,
	position_x:                []f64,
	position_y:                []f64,
	position_z:                []f64,
	texcoord_u:                []f64,
	texcoord_v:                []f64,
	texcoord_w:                []f64,
	normal_x:                  []f64,
	normal_y:                  []f64,
	normal_z:                  []f64,
	source_position_indices:   []u32,
	source_texcoord_indices:   []u32,
	source_normal_indices:     []u32,
	triangle_face_ids:         []contracts.Stable_ID,
	state_records:             []OBJ_State_Record,
	faces:                     []OBJ_Face_Record,
}

OBJ_Counts :: struct {
	positions:         u32,
	texcoords:         u32,
	normals:           u32,
	faces:             u32,
	state_records:     u32,
	triangles:        u32,
	max_face_vertices: u32,
}

OBJ_State_Kind :: enum u8 {
	Object,
	Group,
	Smoothing_Group,
	Material,
	Material_Library,
}

OBJ_State_Record :: struct {
	id:            contracts.Stable_ID,
	kind:          OBJ_State_Kind,
	source_offset: u64,
	source_text:   string,
}

OBJ_Face_Record :: struct {
	id:                    contracts.Stable_ID,
	source_offset:         u64,
	first_triangle:        u32,
	triangle_count:        u32,
	object_state:          u32,
	group_state:           u32,
	smoothing_group_state: u32,
	material_state:        u32,
}

OBJ_Token_Kind :: enum u8 {
	Invalid,
	Token,
	End_Line,
	End_File,
}

OBJ_Token :: struct {
	kind:   OBJ_Token_Kind,
	text:   string,
	offset: int,
}

OBJ_Lexer :: struct {
	bytes:           []u8,
	cursor:          int,
	max_token_bytes: u32,
}

OBJ_Face_Vertex :: struct {
	position: u32,
	texcoord: u32,
	normal:   u32,
}

OBJ_Point_2 :: struct {
	x: f64,
	y: f64,
}

obj_decode :: proc(
	bytes: []u8,
	source_units: contracts.Source_Units,
	limits := DEFAULT_OBJ_LIMITS,
	allocator := context.allocator,
) -> (OBJ_Decoded_Mesh, Decode_Error) {
	if len(bytes) == 0 {return {}, .Empty}
	if u64(len(bytes)) > limits.max_source_bytes {
		return {}, .Source_Limit
	}
	counts, count_error := obj_count(bytes, limits)
	if count_error != .None {return {}, count_error}
	if counts.positions > max(u32)/3 ||
	   counts.triangles > max(u32)/3 {
		return {}, .Index_Overflow
	}

	result: OBJ_Decoded_Mesh
	result.mesh.source = {
		byte_count = u64(len(bytes)),
		format = .OBJ,
		units = source_units,
	}
	_ = crypto_hash.hash_bytes_to_buffer(
		.SHA256,
		bytes,
		result.mesh.source.content_hash[:],
	)
	result.mesh.source_root_id = contracts.stable_id_root(
		result.mesh.source.content_hash,
		.Source,
	)
	if !obj_allocate(&result, counts, allocator) {
		obj_decoded_mesh_destroy(&result, allocator)
		return {}, .Allocation_Failed
	}
	attribute_error := obj_decode_attributes(
		bytes,
		limits,
		counts,
		&result,
		allocator,
	)
	if attribute_error != .None {
		obj_decoded_mesh_destroy(&result, allocator)
		return {}, attribute_error
	}
	face_error := obj_decode_faces(
		bytes,
		limits,
		counts,
		&result,
		allocator,
	)
	if face_error != .None {
		obj_decoded_mesh_destroy(&result, allocator)
		return {}, face_error
	}
	return result, .None
}

obj_source_likely :: proc(
	bytes: []u8,
	limits := DEFAULT_OBJ_LIMITS,
) -> bool {
	if len(bytes) == 0 ||
	   u64(len(bytes)) > limits.max_source_bytes {
		return false
	}
	lexer := obj_lexer_make(bytes, limits.max_token_bytes)
	for {
		statement := obj_next_token(&lexer)
		switch statement.kind {
		case .End_Line:
			continue
		case .Token:
			switch statement.text {
			case "v", "vt", "vn", "vp", "f", "o", "g", "s", "usemtl",
			     "mtllib", "usemap", "maplib", "shadow_obj", "trace_obj",
			     "bevel", "c_interp", "d_interp", "lod", "p", "l",
			     "cstype", "deg", "bmat", "step", "curv", "curv2",
			     "surf", "parm", "trim", "hole", "scrv", "sp", "end",
			     "con":
				return true
			}
			return false
		case .Invalid, .End_File:
			return false
		}
	}
}

obj_count :: proc(
	bytes: []u8,
	limits: OBJ_Limits,
) -> (OBJ_Counts, Decode_Error) {
	lexer := obj_lexer_make(bytes, limits.max_token_bytes)
	counts: OBJ_Counts
	for {
		statement := obj_next_token(&lexer)
		switch statement.kind {
		case .End_Line:
			continue
		case .End_File:
			if counts.positions < 3 || counts.faces == 0 {
				return {}, .Empty
			}
			return counts, .None
		case .Invalid:
			return {}, .Invalid_Syntax
		case .Token:
		}
		switch statement.text {
		case "v":
			values: [4]f64
			value_count, ok := obj_read_float_arguments(&lexer, &values)
			if !ok || (value_count != 3 && value_count != 4) ||
			   (value_count == 4 && values[3] == 0) {
				return {}, .Invalid_Syntax
			}
			if counts.positions >= limits.max_positions {
				return {}, .Triangle_Limit
			}
			counts.positions += 1
		case "vt":
			values: [4]f64
			value_count, ok := obj_read_float_arguments(&lexer, &values)
			if !ok || value_count < 1 || value_count > 3 {
				return {}, .Invalid_Syntax
			}
			if counts.texcoords >= limits.max_texcoords {
				return {}, .Triangle_Limit
			}
			counts.texcoords += 1
		case "vn":
			values: [4]f64
			value_count, ok := obj_read_float_arguments(&lexer, &values)
			if !ok || value_count != 3 {
				return {}, .Invalid_Syntax
			}
			if counts.normals >= limits.max_normals {
				return {}, .Triangle_Limit
			}
			counts.normals += 1
		case "vp":
			values: [4]f64
			value_count, ok := obj_read_float_arguments(&lexer, &values)
			if !ok || value_count < 1 || value_count > 3 {
				return {}, .Invalid_Syntax
			}
		case "f":
			face_vertex_count: u32
			for {
				token := obj_next_token(&lexer)
				if token.kind == .End_Line ||
				   token.kind == .End_File {
					break
				}
				if token.kind != .Token ||
				   !obj_face_reference_syntax_valid(token.text) {
					return {}, .Invalid_Syntax
				}
				face_vertex_count += 1
				if face_vertex_count > limits.max_face_vertices {
					return {}, .Triangle_Limit
				}
			}
			if face_vertex_count < 3 {return {}, .Invalid_Syntax}
			if counts.faces >= limits.max_faces {
				return {}, .Triangle_Limit
			}
			added_triangles := face_vertex_count-2
			if added_triangles > limits.max_triangles ||
			   counts.triangles >
			   limits.max_triangles-added_triangles {
				return {}, .Triangle_Limit
			}
			counts.faces += 1
			counts.triangles += added_triangles
			counts.max_face_vertices = max(
				counts.max_face_vertices,
				face_vertex_count,
			)
		case "o", "g", "s", "usemtl", "mtllib":
			if !obj_skip_line(&lexer) {return {}, .Invalid_Syntax}
			if counts.state_records >= limits.max_state_records {
				return {}, .Triangle_Limit
			}
			counts.state_records += 1
		case "usemap", "maplib", "shadow_obj", "trace_obj", "bevel",
		     "c_interp", "d_interp", "lod", "p", "l":
			if !obj_skip_line(&lexer) {return {}, .Invalid_Syntax}
		case "cstype", "deg", "bmat", "step", "curv", "curv2", "surf",
		     "parm", "trim", "hole", "scrv", "sp", "end", "con":
			return {}, .Invalid_Syntax
		case:
			return {}, .Invalid_Syntax
		}
	}
}

obj_allocate :: proc(
	result: ^OBJ_Decoded_Mesh,
	counts: OBJ_Counts,
	allocator: mem.Allocator,
) -> bool {
	position_count := int(counts.positions)
	texcoord_count := int(counts.texcoords)
	normal_count := int(counts.normals)
	triangle_count := int(counts.triangles)
	vertex_count := triangle_count*3
	result.position_x = make([]f64, position_count, allocator)
	result.position_y = make([]f64, position_count, allocator)
	result.position_z = make([]f64, position_count, allocator)
	result.texcoord_u = make([]f64, texcoord_count, allocator)
	result.texcoord_v = make([]f64, texcoord_count, allocator)
	result.texcoord_w = make([]f64, texcoord_count, allocator)
	result.normal_x = make([]f64, normal_count, allocator)
	result.normal_y = make([]f64, normal_count, allocator)
	result.normal_z = make([]f64, normal_count, allocator)
	result.source_position_indices = make([]u32, vertex_count, allocator)
	result.source_texcoord_indices = make([]u32, vertex_count, allocator)
	result.source_normal_indices = make([]u32, vertex_count, allocator)
	result.triangle_face_ids = make(
		[]contracts.Stable_ID,
		triangle_count,
		allocator,
	)
	result.state_records = make(
		[]OBJ_State_Record,
		int(counts.state_records),
		allocator,
	)
	result.faces = make([]OBJ_Face_Record, int(counts.faces), allocator)
	if !decoded_mesh_allocate(
		&result.mesh,
		vertex_count,
		triangle_count,
		allocator,
	) {
		return false
	}
	if position_count > 0 &&
	   (result.position_x == nil || result.position_y == nil ||
	    result.position_z == nil) {
		return false
	}
	if texcoord_count > 0 &&
	   (result.texcoord_u == nil || result.texcoord_v == nil ||
	    result.texcoord_w == nil) {
		return false
	}
	if normal_count > 0 &&
	   (result.normal_x == nil || result.normal_y == nil ||
	    result.normal_z == nil) {
		return false
	}
	if vertex_count > 0 &&
	   (result.source_position_indices == nil ||
	    result.source_texcoord_indices == nil ||
	    result.source_normal_indices == nil) {
		return false
	}
	if triangle_count > 0 && result.triangle_face_ids == nil {
		return false
	}
	if counts.state_records > 0 && result.state_records == nil {
		return false
	}
	if counts.faces > 0 && result.faces == nil {
		return false
	}
	for index in 0..<vertex_count {
		result.source_texcoord_indices[index] = OBJ_INVALID_INDEX
		result.source_normal_indices[index] = OBJ_INVALID_INDEX
	}
	return true
}

obj_decode_attributes :: proc(
	bytes: []u8,
	limits: OBJ_Limits,
	counts: OBJ_Counts,
	result: ^OBJ_Decoded_Mesh,
	allocator: mem.Allocator,
) -> Decode_Error {
	lexer := obj_lexer_make(bytes, limits.max_token_bytes)
	position_write := 0
	texcoord_write := 0
	normal_write := 0
	state_write := 0
	for {
		statement := obj_next_token(&lexer)
		switch statement.kind {
		case .End_Line:
			continue
		case .End_File:
			if position_write != int(counts.positions) ||
			   texcoord_write != int(counts.texcoords) ||
			   normal_write != int(counts.normals) ||
			   state_write != int(counts.state_records) {
				return .Length_Mismatch
			}
			return .None
		case .Invalid:
			return .Invalid_Syntax
		case .Token:
		}
		switch statement.text {
		case "v":
			values: [4]f64
			value_count, ok := obj_read_float_arguments(&lexer, &values)
			if !ok || (value_count != 3 && value_count != 4) {
				return .Invalid_Syntax
			}
			w := f64(1)
			if value_count == 4 {w = values[3]}
			if w == 0 {return .Invalid_Syntax}
			x := values[0]/w
			y := values[1]/w
			z := values[2]/w
			if !obj_f64_valid(x) || !obj_f64_valid(y) ||
			   !obj_f64_valid(z) {
				return .Non_Finite
			}
			if x == 0 {x = 0}
			if y == 0 {y = 0}
			if z == 0 {z = 0}
			result.position_x[position_write] = x
			result.position_y[position_write] = y
			result.position_z[position_write] = z
			position_write += 1
		case "vt":
			values: [4]f64
			value_count, ok := obj_read_float_arguments(&lexer, &values)
			if !ok || value_count < 1 || value_count > 3 {
				return .Invalid_Syntax
			}
			for &value in values {
				if value == 0 {value = 0}
			}
			result.texcoord_u[texcoord_write] = values[0]
			if value_count >= 2 {
				result.texcoord_v[texcoord_write] = values[1]
			}
			if value_count >= 3 {
				result.texcoord_w[texcoord_write] = values[2]
			}
			texcoord_write += 1
		case "vn":
			values: [4]f64
			value_count, ok := obj_read_float_arguments(&lexer, &values)
			if !ok || value_count != 3 {
				return .Invalid_Syntax
			}
			for &value in values {
				if value == 0 {value = 0}
			}
			result.normal_x[normal_write] = values[0]
			result.normal_y[normal_write] = values[1]
			result.normal_z[normal_write] = values[2]
			normal_write += 1
		case "o", "g", "s", "usemtl", "mtllib":
			if !obj_skip_line(&lexer) {return .Invalid_Syntax}
			if state_write >= len(result.state_records) {
				return .Length_Mismatch
			}
			source_text := strings.clone(
				string(bytes[statement.offset:lexer.cursor]),
				allocator,
			)
			if source_text == "" {return .Allocation_Failed}
			result.state_records[state_write] = {
				id = contracts.stable_id_child(
					result.mesh.source_root_id,
					.Metadata,
					u64(state_write),
				),
				kind = obj_state_kind(statement.text),
				source_offset = u64(statement.offset),
				source_text = source_text,
			}
			state_write += 1
		case:
			if !obj_skip_line(&lexer) {return .Invalid_Syntax}
		}
	}
}

obj_decode_faces :: proc(
	bytes: []u8,
	limits: OBJ_Limits,
	counts: OBJ_Counts,
	result: ^OBJ_Decoded_Mesh,
	allocator: mem.Allocator,
) -> Decode_Error {
	face_vertices := make(
		[]OBJ_Face_Vertex,
		int(counts.max_face_vertices),
		allocator,
	)
	projected := make(
		[]OBJ_Point_2,
		int(counts.max_face_vertices),
		allocator,
	)
	active := make([]int, int(counts.max_face_vertices), allocator)
	if face_vertices == nil || projected == nil || active == nil {
		delete(face_vertices, allocator)
		delete(projected, allocator)
		delete(active, allocator)
		return .Allocation_Failed
	}
	defer delete(face_vertices, allocator)
	defer delete(projected, allocator)
	defer delete(active, allocator)

	lexer := obj_lexer_make(bytes, limits.max_token_bytes)
	positions_seen: u32
	texcoords_seen: u32
	normals_seen: u32
	face_index: u32
	state_index: u32
	object_state := OBJ_INVALID_INDEX
	group_state := OBJ_INVALID_INDEX
	smoothing_group_state := OBJ_INVALID_INDEX
	material_state := OBJ_INVALID_INDEX
	triangle_write := 0
	for {
		statement := obj_next_token(&lexer)
		switch statement.kind {
		case .End_Line:
			continue
		case .End_File:
			if face_index != counts.faces ||
			   triangle_write != int(counts.triangles) {
				return .Length_Mismatch
			}
			return .None
		case .Invalid:
			return .Invalid_Syntax
		case .Token:
		}
		switch statement.text {
		case "v":
			positions_seen += 1
			if !obj_skip_line(&lexer) {return .Invalid_Syntax}
		case "vt":
			texcoords_seen += 1
			if !obj_skip_line(&lexer) {return .Invalid_Syntax}
		case "vn":
			normals_seen += 1
			if !obj_skip_line(&lexer) {return .Invalid_Syntax}
		case "o", "g", "s", "usemtl", "mtllib":
			if !obj_skip_line(&lexer) {return .Invalid_Syntax}
			if state_index >= counts.state_records ||
			   result.state_records[state_index].source_offset !=
			   u64(statement.offset) {
				return .Length_Mismatch
			}
			switch result.state_records[state_index].kind {
			case .Object:
				object_state = state_index
			case .Group:
				group_state = state_index
			case .Smoothing_Group:
				smoothing_group_state = state_index
			case .Material:
				material_state = state_index
			case .Material_Library:
			}
			state_index += 1
		case "f":
			face_vertex_count := 0
			for {
				token := obj_next_token(&lexer)
				if token.kind == .End_Line ||
				   token.kind == .End_File {
					break
				}
				if token.kind != .Token ||
				   face_vertex_count >= len(face_vertices) {
					return .Invalid_Syntax
				}
				reference, reference_ok := obj_face_reference_parse(
					token.text,
					counts,
					positions_seen,
					texcoords_seen,
					normals_seen,
				)
				if !reference_ok {return .Invalid_Syntax}
				face_vertices[face_vertex_count] = reference
				face_vertex_count += 1
			}
			if face_vertex_count < 3 {return .Invalid_Syntax}
			face_id := contracts.stable_id_child(
				result.mesh.source_root_id,
				.Face,
				u64(face_index),
			)
			triangulation_error := obj_triangulate_face(
				result,
				face_vertices[:face_vertex_count],
				projected[:face_vertex_count],
				active[:face_vertex_count],
				face_id,
				u64(statement.offset),
				&triangle_write,
			)
			if triangulation_error != .None {
				return triangulation_error
			}
			result.faces[face_index] = {
				id = face_id,
				source_offset = u64(statement.offset),
				first_triangle = u32(
					triangle_write-(face_vertex_count-2),
				),
				triangle_count = u32(face_vertex_count-2),
				object_state = object_state,
				group_state = group_state,
				smoothing_group_state = smoothing_group_state,
				material_state = material_state,
			}
			face_index += 1
		case:
			if !obj_skip_line(&lexer) {return .Invalid_Syntax}
		}
	}
}

obj_triangulate_face :: proc(
	result: ^OBJ_Decoded_Mesh,
	face: []OBJ_Face_Vertex,
	projected: []OBJ_Point_2,
	active: []int,
	face_id: contracts.Stable_ID,
	source_offset: u64,
	triangle_write: ^int,
) -> Decode_Error {
	if !obj_project_face(result, face, projected) {
		return .Invalid_Syntax
	}
	if !obj_polygon_simple(projected) {return .Invalid_Syntax}
	area := obj_polygon_area_2(projected)
	scale := obj_projected_scale(projected)
	epsilon := max(f64(1e-18), scale*scale*1e-14)
	if math.abs(area) <= epsilon {return .Invalid_Syntax}
	winding := f64(1)
	if area < 0 {winding = -1}
	for index in 0..<len(active) {active[index] = index}
	active_count := len(active)
	local_triangle_index: u64
	for active_count > 3 {
		ear_found := false
		for candidate in 0..<active_count {
			previous := active[(candidate+active_count-1)%active_count]
			current := active[candidate]
			next := active[(candidate+1)%active_count]
			turn := obj_orient_2(
				projected[previous],
				projected[current],
				projected[next],
			)
			if turn*winding <= epsilon {continue}
			contains_vertex := false
			for other_index in 0..<active_count {
				other := active[other_index]
				if other == previous || other == current ||
				   other == next {
					continue
				}
				if obj_point_in_triangle(
					projected[other],
					projected[previous],
					projected[current],
					projected[next],
					winding,
					epsilon,
				) {
					contains_vertex = true
					break
				}
			}
			if contains_vertex {continue}
			obj_emit_face_triangle(
				result,
				face,
				previous,
				current,
				next,
				face_id,
				source_offset,
				local_triangle_index,
				triangle_write,
			)
			local_triangle_index += 1
			for move_index in candidate..<active_count-1 {
				active[move_index] = active[move_index+1]
			}
			active_count -= 1
			ear_found = true
			break
		}
		if !ear_found {return .Invalid_Syntax}
	}
	obj_emit_face_triangle(
		result,
		face,
		active[0],
		active[1],
		active[2],
		face_id,
		source_offset,
		local_triangle_index,
		triangle_write,
	)
	return .None
}

obj_project_face :: proc(
	result: ^OBJ_Decoded_Mesh,
	face: []OBJ_Face_Vertex,
	projected: []OBJ_Point_2,
) -> bool {
	normal_x, normal_y, normal_z: f64
	for vertex_index in 0..<len(face) {
		next_index := (vertex_index+1)%len(face)
		a := face[vertex_index].position
		b := face[next_index].position
		ax := result.position_x[a]
		ay := result.position_y[a]
		az := result.position_z[a]
		bx := result.position_x[b]
		by := result.position_y[b]
		bz := result.position_z[b]
		normal_x += (ay-by)*(az+bz)
		normal_y += (az-bz)*(ax+bx)
		normal_z += (ax-bx)*(ay+by)
	}
	if !obj_f64_valid(normal_x) || !obj_f64_valid(normal_y) ||
	   !obj_f64_valid(normal_z) {
		return false
	}
	normal_length := math.sqrt(
		normal_x*normal_x+normal_y*normal_y+normal_z*normal_z,
	)
	if normal_length == 0 || !obj_f64_valid(normal_length) {return false}
	first := face[0].position
	first_x := result.position_x[first]
	first_y := result.position_y[first]
	first_z := result.position_z[first]
	scale: f64
	for reference in face {
		x := result.position_x[reference.position]
		y := result.position_y[reference.position]
		z := result.position_z[reference.position]
		scale = max(
			scale,
			max(
				math.abs(x-first_x),
				max(math.abs(y-first_y), math.abs(z-first_z)),
			),
		)
	}
	tolerance := max(f64(1e-12), scale*1e-9)
	for reference in face {
		x := result.position_x[reference.position]
		y := result.position_y[reference.position]
		z := result.position_z[reference.position]
		distance := math.abs(
			normal_x*(x-first_x)+
			normal_y*(y-first_y)+
			normal_z*(z-first_z),
		)/normal_length
		if !obj_f64_valid(distance) {return false}
		if distance > tolerance {return false}
	}
	drop_axis := 0
	if math.abs(normal_y) > math.abs(normal_x) {drop_axis = 1}
	if math.abs(normal_z) >
	   (math.abs(normal_y) if drop_axis == 1 else math.abs(normal_x)) {
		drop_axis = 2
	}
	for reference, index in face {
		x := result.position_x[reference.position]
		y := result.position_y[reference.position]
		z := result.position_z[reference.position]
		switch drop_axis {
		case 0: projected[index] = {y, z}
		case 1: projected[index] = {x, z}
		case 2: projected[index] = {x, y}
		}
	}
	return true
}

obj_polygon_simple :: proc(points: []OBJ_Point_2) -> bool {
	for edge_a in 0..<len(points) {
		a0 := points[edge_a]
		a1 := points[(edge_a+1)%len(points)]
		if a0 == a1 {return false}
		for edge_b in edge_a+1..<len(points) {
			if edge_b == edge_a ||
			   edge_b == (edge_a+1)%len(points) ||
			   (edge_b+1)%len(points) == edge_a {
				continue
			}
			b0 := points[edge_b]
			b1 := points[(edge_b+1)%len(points)]
			if obj_segments_intersect(a0, a1, b0, b1) {return false}
		}
	}
	return true
}

obj_segments_intersect :: proc(
	a0, a1, b0, b1: OBJ_Point_2,
) -> bool {
	o0 := obj_orient_2(a0, a1, b0)
	o1 := obj_orient_2(a0, a1, b1)
	o2 := obj_orient_2(b0, b1, a0)
	o3 := obj_orient_2(b0, b1, a1)
	if o0 == 0 && obj_point_on_segment(b0, a0, a1) {return true}
	if o1 == 0 && obj_point_on_segment(b1, a0, a1) {return true}
	if o2 == 0 && obj_point_on_segment(a0, b0, b1) {return true}
	if o3 == 0 && obj_point_on_segment(a1, b0, b1) {return true}
	return (o0 < 0) != (o1 < 0) && (o2 < 0) != (o3 < 0)
}

obj_point_on_segment :: proc(
	point, a, b: OBJ_Point_2,
) -> bool {
	return point.x >= min(a.x, b.x) && point.x <= max(a.x, b.x) &&
		point.y >= min(a.y, b.y) && point.y <= max(a.y, b.y)
}

obj_polygon_area_2 :: proc(points: []OBJ_Point_2) -> f64 {
	area: f64
	for point, index in points {
		next := points[(index+1)%len(points)]
		area += point.x*next.y-next.x*point.y
	}
	return area
}

obj_projected_scale :: proc(points: []OBJ_Point_2) -> f64 {
	minimum_x, maximum_x := points[0].x, points[0].x
	minimum_y, maximum_y := points[0].y, points[0].y
	for point in points[1:] {
		minimum_x = min(minimum_x, point.x)
		maximum_x = max(maximum_x, point.x)
		minimum_y = min(minimum_y, point.y)
		maximum_y = max(maximum_y, point.y)
	}
	return max(maximum_x-minimum_x, maximum_y-minimum_y)
}

obj_orient_2 :: proc(a, b, c: OBJ_Point_2) -> f64 {
	return (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
}

obj_point_in_triangle :: proc(
	point, a, b, c: OBJ_Point_2,
	winding, epsilon: f64,
) -> bool {
	return obj_orient_2(a, b, point)*winding >= -epsilon &&
		obj_orient_2(b, c, point)*winding >= -epsilon &&
		obj_orient_2(c, a, point)*winding >= -epsilon
}

obj_emit_face_triangle :: proc(
	result: ^OBJ_Decoded_Mesh,
	face: []OBJ_Face_Vertex,
	a, b, c: int,
	face_id: contracts.Stable_ID,
	source_offset: u64,
	local_triangle_index: u64,
	triangle_write: ^int,
) {
	triangle_index := triangle_write^
	triangle_id := contracts.stable_id_child(
		face_id,
		.Triangle,
		local_triangle_index,
	)
	first_vertex := triangle_index*3
	result.mesh.triangle_a[triangle_index] = u32(first_vertex)
	result.mesh.triangle_b[triangle_index] = u32(first_vertex+1)
	result.mesh.triangle_c[triangle_index] = u32(first_vertex+2)
	result.mesh.triangle_ids[triangle_index] = triangle_id
	result.mesh.source_record_offsets[triangle_index] = source_offset
	result.triangle_face_ids[triangle_index] = face_id
	face_indices := [3]int{a, b, c}
	for face_vertex_index, local_vertex in face_indices {
		reference := face[face_vertex_index]
		vertex_index := first_vertex+local_vertex
		result.mesh.vertex_x[vertex_index] =
			result.position_x[reference.position]
		result.mesh.vertex_y[vertex_index] =
			result.position_y[reference.position]
		result.mesh.vertex_z[vertex_index] =
			result.position_z[reference.position]
		result.mesh.vertex_ids[vertex_index] = contracts.stable_id_child(
			triangle_id,
			.Vertex,
			u64(local_vertex),
		)
		result.source_position_indices[vertex_index] = reference.position
		result.source_texcoord_indices[vertex_index] = reference.texcoord
		result.source_normal_indices[vertex_index] = reference.normal
	}
	triangle_write^ += 1
}

obj_face_reference_parse :: proc(
	text: string,
	counts: OBJ_Counts,
	positions_seen, texcoords_seen, normals_seen: u32,
) -> (OBJ_Face_Vertex, bool) {
	parts: [3]string
	part_count := 1
	part_start := 0
	for value, index in text {
		if value != '/' {continue}
		if part_count >= 3 {return {}, false}
		parts[part_count-1] = text[part_start:index]
		part_count += 1
		part_start = index+1
	}
	parts[part_count-1] = text[part_start:]
	if parts[0] == "" {return {}, false}
	position_value, position_ok := obj_parse_i64(parts[0])
	position, position_found := obj_resolve_index(
		position_value,
		counts.positions,
		positions_seen,
	)
	if !position_ok || !position_found {return {}, false}
	result := OBJ_Face_Vertex{
		position = position,
		texcoord = OBJ_INVALID_INDEX,
		normal = OBJ_INVALID_INDEX,
	}
	if part_count >= 2 && parts[1] != "" {
		texcoord_value, texcoord_ok := obj_parse_i64(parts[1])
		texcoord, texcoord_found := obj_resolve_index(
			texcoord_value,
			counts.texcoords,
			texcoords_seen,
		)
		if !texcoord_ok || !texcoord_found {return {}, false}
		result.texcoord = texcoord
	} else if part_count == 2 {
		return {}, false
	}
	if part_count == 3 {
		if parts[2] == "" {return {}, false}
		normal_value, normal_ok := obj_parse_i64(parts[2])
		normal, normal_found := obj_resolve_index(
			normal_value,
			counts.normals,
			normals_seen,
		)
		if !normal_ok || !normal_found {return {}, false}
		result.normal = normal
	}
	return result, true
}

obj_face_reference_syntax_valid :: proc(text: string) -> bool {
	parts: [3]string
	part_count := 1
	part_start := 0
	for value, index in text {
		if value != '/' {continue}
		if part_count >= 3 {return false}
		parts[part_count-1] = text[part_start:index]
		part_count += 1
		part_start = index+1
	}
	parts[part_count-1] = text[part_start:]
	if parts[0] == "" {return false}
	if _, ok := obj_parse_i64(parts[0]); !ok {return false}
	if part_count >= 2 && parts[1] != "" {
		if _, ok := obj_parse_i64(parts[1]); !ok {return false}
	} else if part_count == 2 {
		return false
	}
	if part_count == 3 {
		if parts[2] == "" {return false}
		if _, ok := obj_parse_i64(parts[2]); !ok {return false}
	}
	return true
}

obj_resolve_index :: proc(
	value: i64,
	total, seen: u32,
) -> (u32, bool) {
	if value == 0 {return 0, false}
	if value > 0 {
		index := u64(value-1)
		if index >= u64(total) {return 0, false}
		return u32(index), true
	}
	magnitude := u64(-(value+1))+1
	if magnitude > u64(seen) {return 0, false}
	return seen-u32(magnitude), true
}

obj_parse_i64 :: proc(text: string) -> (i64, bool) {
	if text == "" {return 0, false}
	negative := false
	cursor := 0
	if text[0] == '+' || text[0] == '-' {
		negative = text[0] == '-'
		cursor = 1
		if cursor == len(text) {return 0, false}
	}
	limit := u64(max(i64))
	if negative {limit += 1}
	value: u64
	for cursor < len(text) {
		digit := text[cursor]
		if digit < '0' || digit > '9' {return 0, false}
		digit_value := u64(digit-'0')
		if value > (limit-digit_value)/10 {return 0, false}
		value = value*10+digit_value
		cursor += 1
	}
	if negative {
		if value == u64(max(i64))+1 {return min(i64), true}
		return -i64(value), true
	}
	return i64(value), true
}

obj_read_float_arguments :: proc(
	lexer: ^OBJ_Lexer,
	values: ^[4]f64,
) -> (int, bool) {
	count := 0
	for {
		token := obj_next_token(lexer)
		if token.kind == .End_Line || token.kind == .End_File {
			return count, true
		}
		if token.kind != .Token || count >= len(values) {
			return 0, false
		}
		value, value_ok := three_mf_parse_f64(token.text)
		if !value_ok {return 0, false}
		values[count] = value
		count += 1
	}
}

obj_skip_line :: proc(lexer: ^OBJ_Lexer) -> bool {
	for {
		token := obj_next_token(lexer)
		if token.kind == .End_Line || token.kind == .End_File {
			return true
		}
		if token.kind == .Invalid {return false}
	}
}

obj_next_token :: proc(lexer: ^OBJ_Lexer) -> OBJ_Token {
	for {
		if lexer.cursor >= len(lexer.bytes) {
			return {kind = .End_File, offset = lexer.cursor}
		}
		value := lexer.bytes[lexer.cursor]
		if value == 0 {return {kind = .Invalid, offset = lexer.cursor}}
		if value == ' ' || value == '\t' ||
		   value == 0x0b || value == 0x0c {
			lexer.cursor += 1
			continue
		}
		if value == '\r' || value == '\n' {
			offset := lexer.cursor
			if value == '\r' {lexer.cursor += 1}
			if lexer.cursor < len(lexer.bytes) &&
			   lexer.bytes[lexer.cursor] == '\n' {
				lexer.cursor += 1
			} else if value == '\n' {
				lexer.cursor += 1
			}
			return {kind = .End_Line, offset = offset}
		}
		if value == '#' {
			for lexer.cursor < len(lexer.bytes) &&
			    lexer.bytes[lexer.cursor] != '\r' &&
			    lexer.bytes[lexer.cursor] != '\n' {
				lexer.cursor += 1
			}
			continue
		}
		if value == '\\' {
			lookahead := lexer.cursor+1
			for lookahead < len(lexer.bytes) &&
			    (lexer.bytes[lookahead] == ' ' ||
			     lexer.bytes[lookahead] == '\t') {
				lookahead += 1
			}
			if lookahead < len(lexer.bytes) &&
			   (lexer.bytes[lookahead] == '\r' ||
			    lexer.bytes[lookahead] == '\n') {
				lexer.cursor = lookahead
				if lexer.bytes[lexer.cursor] == '\r' {
					lexer.cursor += 1
				}
				if lexer.cursor < len(lexer.bytes) &&
				   lexer.bytes[lexer.cursor] == '\n' {
					lexer.cursor += 1
				} else if lexer.bytes[lookahead] == '\n' {
					lexer.cursor += 1
				}
				continue
			}
			return {kind = .Invalid, offset = lexer.cursor}
		}
		start := lexer.cursor
		for lexer.cursor < len(lexer.bytes) {
			value = lexer.bytes[lexer.cursor]
			if value == 0 {return {kind = .Invalid, offset = start}}
			if value == ' ' || value == '\t' ||
			   value == '\r' || value == '\n' ||
			   value == 0x0b || value == 0x0c ||
			   value == '#' || value == '\\' {
				break
			}
			lexer.cursor += 1
		}
		token_length := lexer.cursor-start
		if token_length == 0 ||
		   u64(token_length) > u64(lexer.max_token_bytes) {
			return {kind = .Invalid, offset = start}
		}
		return {
			kind = .Token,
			text = string(lexer.bytes[start:lexer.cursor]),
			offset = start,
		}
	}
}

obj_f64_valid :: proc(value: f64) -> bool {
	return !math.is_nan(value) && !math.is_inf(value)
}

obj_lexer_make :: proc(bytes: []u8, max_token_bytes: u32) -> OBJ_Lexer {
	cursor := 0
	if len(bytes) >= 3 &&
	   bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf {
		cursor = 3
	}
	return {
		bytes = bytes,
		cursor = cursor,
		max_token_bytes = max_token_bytes,
	}
}

obj_state_kind :: proc(statement: string) -> OBJ_State_Kind {
	switch statement {
	case "o":      return .Object
	case "g":      return .Group
	case "s":      return .Smoothing_Group
	case "usemtl": return .Material
	case "mtllib": return .Material_Library
	}
	unreachable()
}

obj_decoded_mesh_destroy :: proc(
	result: ^OBJ_Decoded_Mesh,
	allocator := context.allocator,
) {
	decoded_mesh_destroy(&result.mesh, allocator)
	delete(result.position_x, allocator)
	delete(result.position_y, allocator)
	delete(result.position_z, allocator)
	delete(result.texcoord_u, allocator)
	delete(result.texcoord_v, allocator)
	delete(result.texcoord_w, allocator)
	delete(result.normal_x, allocator)
	delete(result.normal_y, allocator)
	delete(result.normal_z, allocator)
	delete(result.source_position_indices, allocator)
	delete(result.source_texcoord_indices, allocator)
	delete(result.source_normal_indices, allocator)
	delete(result.triangle_face_ids, allocator)
	for record in result.state_records {
		delete(transmute([]u8)record.source_text, allocator)
	}
	delete(result.state_records, allocator)
	delete(result.faces, allocator)
	result^ = {}
}
