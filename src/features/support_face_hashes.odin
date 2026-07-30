package features

import contracts "../contracts"
import geometry "../geometry"
import profiles "../profiles"

SCHEMA_VERSION_SUPPORT_FACE_HASH :: u32(1)

support_face_result_hash :: proc(
	mesh_hash: contracts.Content_Hash,
	process_hash: contracts.Content_Hash,
	mesh: geometry.Canonical_Mesh,
	process: profiles.Resolved_Process_Profile,
	result: Support_Face_Result,
	limits := DEFAULT_SUPPORT_FACE_LIMITS,
	allocator := context.allocator,
) -> (contracts.Content_Hash, bool) {
	calculated_mesh_hash, mesh_ok := geometry.canonical_mesh_hash(mesh)
	if !mesh_ok || calculated_mesh_hash != mesh_hash {
		return {}, false
	}
	expected, expected_error := support_faces_classify(
		mesh,
		process,
		limits,
		allocator,
	)
	if expected_error != .None {return {}, false}
	defer support_face_result_destroy(&expected, allocator)
	if result.policy != expected.policy ||
	   result.overhang_angle != expected.overhang_angle ||
	   result.threshold_sine_squared != expected.threshold_sine_squared ||
	   result.degenerate_count != expected.degenerate_count ||
	   result.upward_or_vertical_count !=
	    expected.upward_or_vertical_count ||
	   result.within_limit_count != expected.within_limit_count ||
	   result.overhang_count != expected.overhang_count ||
	   len(result.faces) != len(expected.faces) ||
	   len(result.points) != len(expected.points) {
		return {}, false
	}
	for face, face_index in result.faces {
		if face != expected.faces[face_index] {return {}, false}
	}
	for point, point_index in result.points {
		if point != expected.points[point_index] {return {}, false}
	}

	hash: contracts.Canonical_Hash
	contracts.canonical_hash_init(
		&hash,
		"hw-slicer/support-faces",
		SCHEMA_VERSION_SUPPORT_FACE_HASH,
	)
	contracts.canonical_hash_append_content_hash(&hash, mesh_hash)
	contracts.canonical_hash_append_content_hash(&hash, process_hash)
	contracts.canonical_hash_append_u8(&hash, u8(result.policy))
	contracts.canonical_hash_append_i64(
		&hash,
		i64(result.overhang_angle),
	)
	contracts.canonical_hash_append_f64_bits(
		&hash,
		result.threshold_sine_squared,
	)
	contracts.canonical_hash_append_u64(&hash, result.degenerate_count)
	contracts.canonical_hash_append_u64(
		&hash,
		result.upward_or_vertical_count,
	)
	contracts.canonical_hash_append_u64(&hash, result.within_limit_count)
	contracts.canonical_hash_append_u64(&hash, result.overhang_count)
	contracts.canonical_hash_append_u64(&hash, u64(len(result.faces)))
	for face in result.faces {
		contracts.canonical_hash_append_stable_id(&hash, face.stable_id)
		contracts.canonical_hash_append_stable_id(&hash, face.triangle_id)
		contracts.canonical_hash_append_u32(&hash, face.triangle_index)
		contracts.canonical_hash_append_u8(&hash, u8(face.kind))
		contracts.canonical_hash_append_f64_bits(&hash, face.normal_x)
		contracts.canonical_hash_append_f64_bits(&hash, face.normal_y)
		contracts.canonical_hash_append_f64_bits(&hash, face.normal_z)
		contracts.canonical_hash_append_f64_bits(
			&hash,
			face.normal_length_squared,
		)
		contracts.canonical_hash_append_f64_bits(
			&hash,
			face.downward_z_squared,
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(face.minimum_z),
		)
		contracts.canonical_hash_append_i64(
			&hash,
			i64(face.maximum_z),
		)
		contracts.canonical_hash_append_u64(&hash, face.point_offset)
		contracts.canonical_hash_append_u8(&hash, face.point_count)
		contracts.canonical_hash_append_i128(
			&hash,
			face.projected_area_2,
		)
	}
	contracts.canonical_hash_append_u64(&hash, u64(len(result.points)))
	for point in result.points {
		contracts.canonical_hash_append_i64(&hash, i64(point.x))
		contracts.canonical_hash_append_i64(&hash, i64(point.y))
	}
	return contracts.canonical_hash_final(&hash), true
}
