package geometry

import "core:math"

import contracts "../contracts"
import formats "../formats"

Mesh_Bounds :: struct {
	minimum: Point_3,
	maximum: Point_3,
}

Canonical_Mesh :: struct {
	source:                contracts.Source_Asset,
	coordinate_units:      contracts.Source_Units,
	source_root_id:        contracts.Stable_ID,
	bounds:                Mesh_Bounds,
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

Normalize_Error :: enum u8 {
	None,
	Invalid_Input,
	Unsupported_Units,
	Non_Finite,
	Allocation_Failed,
}

mesh_normalize_units :: proc(
	decoded: formats.Decoded_Mesh,
	allocator := context.allocator,
) -> (Canonical_Mesh, Normalize_Error) {
	vertex_count := len(decoded.vertex_x)
	triangle_count := len(decoded.triangle_ids)
	if vertex_count == 0 ||
	   len(decoded.vertex_y) != vertex_count ||
	   len(decoded.vertex_z) != vertex_count ||
	   len(decoded.vertex_ids) != vertex_count ||
	   len(decoded.triangle_a) != triangle_count ||
	   len(decoded.triangle_b) != triangle_count ||
	   len(decoded.triangle_c) != triangle_count ||
	   len(decoded.source_record_offsets) != triangle_count {
		return {}, .Invalid_Input
	}
	scale, scale_ok := source_units_to_millimetres(decoded.source.units)
	if !scale_ok {return {}, .Unsupported_Units}

	mesh: Canonical_Mesh
	mesh.source = decoded.source
	mesh.coordinate_units = .Millimetres
	mesh.source_root_id = decoded.source_root_id
	mesh.vertex_x = make([]f64, vertex_count, allocator)
	mesh.vertex_y = make([]f64, vertex_count, allocator)
	mesh.vertex_z = make([]f64, vertex_count, allocator)
	mesh.vertex_ids = make([]contracts.Stable_ID, vertex_count, allocator)
	mesh.triangle_a = make([]u32, triangle_count, allocator)
	mesh.triangle_b = make([]u32, triangle_count, allocator)
	mesh.triangle_c = make([]u32, triangle_count, allocator)
	mesh.triangle_ids = make([]contracts.Stable_ID, triangle_count, allocator)
	mesh.source_record_offsets = make([]u64, triangle_count, allocator)
	if mesh.vertex_x == nil || mesh.vertex_y == nil || mesh.vertex_z == nil ||
	   mesh.vertex_ids == nil || mesh.triangle_a == nil ||
	   mesh.triangle_b == nil || mesh.triangle_c == nil ||
	   mesh.triangle_ids == nil || mesh.source_record_offsets == nil {
		canonical_mesh_destroy(&mesh, allocator)
		return {}, .Allocation_Failed
	}

	for vertex_index in 0..<vertex_count {
		x := decoded.vertex_x[vertex_index]*scale
		y := decoded.vertex_y[vertex_index]*scale
		z := decoded.vertex_z[vertex_index]*scale
		if math.is_nan(x) || math.is_inf(x) ||
		   math.is_nan(y) || math.is_inf(y) ||
		   math.is_nan(z) || math.is_inf(z) {
			canonical_mesh_destroy(&mesh, allocator)
			return {}, .Non_Finite
		}
		if x == 0 {x = 0}
		if y == 0 {y = 0}
		if z == 0 {z = 0}
		mesh.vertex_x[vertex_index] = x
		mesh.vertex_y[vertex_index] = y
		mesh.vertex_z[vertex_index] = z
		mesh.vertex_ids[vertex_index] = decoded.vertex_ids[vertex_index]
		if vertex_index == 0 {
			mesh.bounds.minimum = {
				contracts.Millimetres(x),
				contracts.Millimetres(y),
				contracts.Millimetres(z),
			}
			mesh.bounds.maximum = mesh.bounds.minimum
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
	copy(mesh.triangle_a, decoded.triangle_a)
	copy(mesh.triangle_b, decoded.triangle_b)
	copy(mesh.triangle_c, decoded.triangle_c)
	copy(mesh.triangle_ids, decoded.triangle_ids)
	copy(mesh.source_record_offsets, decoded.source_record_offsets)
	return mesh, .None
}

canonical_mesh_destroy :: proc(
	mesh: ^Canonical_Mesh,
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

source_units_to_millimetres :: proc(
	units: contracts.Source_Units,
) -> (f64, bool) {
	switch units {
	case .Micrometres: return 0.001, true
	case .Millimetres: return 1, true
	case .Centimetres: return 10, true
	case .Metres:      return 1000, true
	case .Inches:      return 25.4, true
	case .Feet:        return 304.8, true
	case .Unspecified: return 0, false
	}
	return 0, false
}
