package geometry

import "core:math"

import contracts "../contracts"

SCHEMA_VERSION_CANONICAL_MESH_HASH :: u32(1)
SCHEMA_VERSION_MESH_AUDIT_HASH :: u32(1)

canonical_mesh_hash :: proc(
	mesh: Canonical_Mesh,
) -> (contracts.Content_Hash, bool) {
	vertex_count := len(mesh.vertex_x)
	triangle_count := len(mesh.triangle_ids)
	if vertex_count == 0 || triangle_count == 0 ||
	   len(mesh.vertex_y) != vertex_count ||
	   len(mesh.vertex_z) != vertex_count ||
	   len(mesh.vertex_ids) != vertex_count ||
	   len(mesh.triangle_a) != triangle_count ||
	   len(mesh.triangle_b) != triangle_count ||
	   len(mesh.triangle_c) != triangle_count ||
	   len(mesh.source_record_offsets) != triangle_count ||
	   mesh.coordinate_units != .Millimetres ||
	   mesh.source_root_id == contracts.INVALID_STABLE_ID ||
	   !canonical_mesh_hash_bounds_valid(mesh.bounds) {
		return {}, false
	}
	for vertex_index in 0..<vertex_count {
		if !canonical_mesh_hash_coordinate_valid(mesh.vertex_x[vertex_index]) ||
		   !canonical_mesh_hash_coordinate_valid(mesh.vertex_y[vertex_index]) ||
		   !canonical_mesh_hash_coordinate_valid(mesh.vertex_z[vertex_index]) ||
		   mesh.vertex_ids[vertex_index] == contracts.INVALID_STABLE_ID {
			return {}, false
		}
	}
	for triangle_index in 0..<triangle_count {
		if u64(mesh.triangle_a[triangle_index]) >= u64(vertex_count) ||
		   u64(mesh.triangle_b[triangle_index]) >= u64(vertex_count) ||
		   u64(mesh.triangle_c[triangle_index]) >= u64(vertex_count) ||
		   mesh.triangle_ids[triangle_index] == contracts.INVALID_STABLE_ID {
			return {}, false
		}
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/canonical-mesh",
		SCHEMA_VERSION_CANONICAL_MESH_HASH,
	)
	contracts.canonical_hash_append_content_hash(
		&hash,
		mesh.source.content_hash,
	)
	contracts.canonical_hash_append_u64(&hash, mesh.source.byte_count)
	contracts.canonical_hash_append_u8(&hash, u8(mesh.source.format))
	contracts.canonical_hash_append_u8(&hash, u8(mesh.source.units))
	contracts.canonical_hash_append_u8(&hash, u8(mesh.coordinate_units))
	contracts.canonical_hash_append_stable_id(&hash, mesh.source_root_id)
	canonical_mesh_hash_append_bounds(&hash, mesh.bounds)
	contracts.canonical_hash_append_u64(&hash, u64(vertex_count))
	for vertex_index in 0..<vertex_count {
		contracts.canonical_hash_append_f64_bits(
			&hash,
			mesh.vertex_x[vertex_index],
		)
		contracts.canonical_hash_append_f64_bits(
			&hash,
			mesh.vertex_y[vertex_index],
		)
		contracts.canonical_hash_append_f64_bits(
			&hash,
			mesh.vertex_z[vertex_index],
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			mesh.vertex_ids[vertex_index],
		)
	}
	contracts.canonical_hash_append_u64(&hash, u64(triangle_count))
	for triangle_index in 0..<triangle_count {
		contracts.canonical_hash_append_u32(
			&hash,
			mesh.triangle_a[triangle_index],
		)
		contracts.canonical_hash_append_u32(
			&hash,
			mesh.triangle_b[triangle_index],
		)
		contracts.canonical_hash_append_u32(
			&hash,
			mesh.triangle_c[triangle_index],
		)
		contracts.canonical_hash_append_stable_id(
			&hash,
			mesh.triangle_ids[triangle_index],
		)
		contracts.canonical_hash_append_u64(
			&hash,
			mesh.source_record_offsets[triangle_index],
		)
	}
	return contracts.canonical_hash_final(&hash), true
}

canonical_mesh_hash_coordinate_valid :: proc(value: f64) -> bool {
	if math.is_nan(value) || math.is_inf(value) {return false}
	return value != 0 || transmute(u64)value == 0
}

canonical_mesh_hash_bounds_valid :: proc(bounds: Mesh_Bounds) -> bool {
	values := [6]f64{
		f64(bounds.minimum.x),
		f64(bounds.minimum.y),
		f64(bounds.minimum.z),
		f64(bounds.maximum.x),
		f64(bounds.maximum.y),
		f64(bounds.maximum.z),
	}
	for value in values {
		if !canonical_mesh_hash_coordinate_valid(value) {return false}
	}
	return bounds.minimum.x <= bounds.maximum.x &&
		bounds.minimum.y <= bounds.maximum.y &&
		bounds.minimum.z <= bounds.maximum.z
}

canonical_mesh_hash_append_bounds :: proc(
	hash: ^contracts.Canonical_Hash,
	bounds: Mesh_Bounds,
) {
	contracts.canonical_hash_append_f64_bits(hash, f64(bounds.minimum.x))
	contracts.canonical_hash_append_f64_bits(hash, f64(bounds.minimum.y))
	contracts.canonical_hash_append_f64_bits(hash, f64(bounds.minimum.z))
	contracts.canonical_hash_append_f64_bits(hash, f64(bounds.maximum.x))
	contracts.canonical_hash_append_f64_bits(hash, f64(bounds.maximum.y))
	contracts.canonical_hash_append_f64_bits(hash, f64(bounds.maximum.z))
}

mesh_audit_hash :: proc(
	mesh_hash: contracts.Content_Hash,
	result: Mesh_Audit_Result,
) -> (contracts.Content_Hash, bool) {
	expected_triangle_offset: u64
	degenerate_count: u64
	duplicate_count: u64
	boundary_count: u64
	non_manifold_count: u64
	winding_count: u64
	for issue in result.issues {
		if issue.stable_id == contracts.INVALID_STABLE_ID ||
		   issue.code == .Invalid ||
		   issue.triangle_count == 0 ||
		   issue.triangle_offset != expected_triangle_offset ||
		   issue.triangle_offset+u64(issue.triangle_count) >
		   	u64(len(result.triangle_ids)) ||
		   issue.has_edge ==
		   	(issue.code == .Degenerate_Triangle ||
		   	 issue.code == .Duplicate_Face) {
			return {}, false
		}
		if issue.has_edge &&
		   (point_3_validate(issue.edge_a) != .None ||
		    point_3_validate(issue.edge_b) != .None ||
		    !canonical_mesh_hash_coordinate_valid(f64(issue.edge_a.x)) ||
		    !canonical_mesh_hash_coordinate_valid(f64(issue.edge_a.y)) ||
		    !canonical_mesh_hash_coordinate_valid(f64(issue.edge_a.z)) ||
		    !canonical_mesh_hash_coordinate_valid(f64(issue.edge_b.x)) ||
		    !canonical_mesh_hash_coordinate_valid(f64(issue.edge_b.y)) ||
		    !canonical_mesh_hash_coordinate_valid(f64(issue.edge_b.z))) {
			return {}, false
		}
		switch issue.code {
		case .Degenerate_Triangle:
			if issue.triangle_count != 1 {return {}, false}
			degenerate_count += 1
		case .Boundary_Edge:
			if issue.triangle_count != 1 {return {}, false}
			boundary_count += 1
		case .Non_Manifold_Edge:
			if issue.triangle_count < 3 {return {}, false}
			non_manifold_count += 1
		case .Inconsistent_Winding:
			if issue.triangle_count != 2 {return {}, false}
			winding_count += 1
		case .Duplicate_Face:
			if issue.triangle_count < 2 {return {}, false}
			duplicate_count += 1
		case .Invalid:
			return {}, false
		}
		expected_triangle_offset += u64(issue.triangle_count)
	}
	if expected_triangle_offset != u64(len(result.triangle_ids)) ||
	   degenerate_count != result.degenerate_triangle_count ||
	   duplicate_count != result.duplicate_face_group_count ||
	   boundary_count != result.boundary_edge_count ||
	   non_manifold_count != result.non_manifold_edge_count ||
	   winding_count != result.inconsistent_winding_count {
		return {}, false
	}
	for triangle_id in result.triangle_ids {
		if triangle_id == contracts.INVALID_STABLE_ID {return {}, false}
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/mesh-audit",
		SCHEMA_VERSION_MESH_AUDIT_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, mesh_hash)
	contracts.canonical_hash_append_u64(
		&hash,
		result.welded_vertex_count,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.degenerate_triangle_count,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.duplicate_face_group_count,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.boundary_edge_count,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.non_manifold_edge_count,
	)
	contracts.canonical_hash_append_u64(
		&hash,
		result.inconsistent_winding_count,
	)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.issues)))
	for issue in result.issues {
		contracts.canonical_hash_append_stable_id(&hash, issue.stable_id)
		contracts.canonical_hash_append_u8(&hash, u8(issue.code))
		has_edge := u8(0)
		if issue.has_edge {has_edge = 1}
		contracts.canonical_hash_append_u8(&hash, has_edge)
		if issue.has_edge {
			contracts.canonical_hash_append_f64_bits(
				&hash,
				f64(issue.edge_a.x),
			)
			contracts.canonical_hash_append_f64_bits(
				&hash,
				f64(issue.edge_a.y),
			)
			contracts.canonical_hash_append_f64_bits(
				&hash,
				f64(issue.edge_a.z),
			)
			contracts.canonical_hash_append_f64_bits(
				&hash,
				f64(issue.edge_b.x),
			)
			contracts.canonical_hash_append_f64_bits(
				&hash,
				f64(issue.edge_b.y),
			)
			contracts.canonical_hash_append_f64_bits(
				&hash,
				f64(issue.edge_b.z),
			)
		}
		contracts.canonical_hash_append_u64(
			&hash,
			issue.triangle_offset,
		)
		contracts.canonical_hash_append_u32(
			&hash,
			issue.triangle_count,
		)
	}
	contracts.canonical_hash_append_u64(
		&hash,
		u64(len(result.triangle_ids)),
	)
	for triangle_id in result.triangle_ids {
		contracts.canonical_hash_append_stable_id(&hash, triangle_id)
	}
	return contracts.canonical_hash_final(&hash), true
}
