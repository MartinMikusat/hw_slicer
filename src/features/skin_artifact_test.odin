package features

import "core:crypto/sha2"
import "core:testing"

import contracts "../contracts"
import polygon "../polygon"
import slicing "../slicing"

@(test)
skin_artifact_round_trip_matches_golden_bytes_test :: proc(t: ^testing.T) {
	heights := [?]contracts.Micrometres{200, 200, 200}
	topology, regions, surfaces := skin_test_plate(t, len(heights))
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer surface_result_destroy(&surfaces)
	region_hash, region_hash_ok := slicing.region_result_hash(
		{},
		topology,
		regions,
	)
	surface_hash, surface_hash_ok := surface_result_hash(
		region_hash,
		surfaces,
	)
	result, result_error := skins_propagate(
		topology,
		regions,
		surfaces,
		heights[:],
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			top = {600, 3},
			bottom = {600, 3},
		},
	)
	defer skin_result_destroy(&result)
	testing.expect(t, region_hash_ok)
	testing.expect(t, surface_hash_ok)
	testing.expect_value(t, result_error, Skin_Error.None)
	bytes, encode_error := skin_artifact_encode(
		surface_hash,
		Skin_Artifact_Test_Schedule_Hash,
		heights[:],
		regions,
		surfaces,
		result,
	)
	defer delete(bytes)
	testing.expect_value(t, encode_error, Skin_Artifact_Error.None)
	artifact, decode_error := skin_artifact_decode(
		bytes,
		surface_hash,
		Skin_Artifact_Test_Schedule_Hash,
		regions,
		surfaces,
	)
	defer skin_artifact_destroy(&artifact)
	testing.expect_value(t, decode_error, Skin_Artifact_Error.None)
	testing.expect_value(t, len(bytes), 1192)
	testing.expect_value(t, len(artifact.layer_heights), 3)
	testing.expect_value(t, len(artifact.result.layers), 3)
	testing.expect_value(t, len(artifact.result.masks), 3)
	testing.expect_value(t, len(artifact.result.paths), 3)
	testing.expect_value(t, len(artifact.result.points), 12)
	testing.expect_value(t, len(artifact.result.source_references), 6)
	testing.expect_value(t, artifact.result.bottom_mask_count, u64(0))
	testing.expect_value(t, artifact.result.top_mask_count, u64(0))
	testing.expect_value(t, artifact.result.top_bottom_mask_count, u64(3))
	for height, height_index in artifact.layer_heights {
		testing.expect_value(t, height, heights[height_index])
	}
	for layer, layer_index in artifact.result.layers {
		testing.expect_value(t, layer, result.layers[layer_index])
	}
	for mask, mask_index in artifact.result.masks {
		testing.expect_value(t, mask, result.masks[mask_index])
	}
	for path, path_index in artifact.result.paths {
		testing.expect_value(t, path, result.paths[path_index])
	}
	for point, point_index in artifact.result.points {
		testing.expect_value(t, point, result.points[point_index])
	}
	for reference, reference_index in artifact.result.source_references {
		testing.expect_value(
			t,
			reference,
			result.source_references[reference_index],
		)
	}
	reencoded, reencode_error := skin_artifact_encode(
		surface_hash,
		Skin_Artifact_Test_Schedule_Hash,
		artifact.layer_heights,
		regions,
		surfaces,
		artifact.result,
	)
	defer delete(reencoded)
	testing.expect_value(t, reencode_error, Skin_Artifact_Error.None)
	testing.expect(t, skin_artifact_test_bytes_equal(reencoded, bytes))
	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	testing.expect_value(t, digest, Skin_Artifact_Test_Digest)
}

@(test)
skin_artifact_rejects_framing_dependencies_limits_and_corruption_test :: proc(
	t: ^testing.T,
) {
	heights := [?]contracts.Micrometres{200, 200, 200}
	topology, regions, surfaces := skin_test_plate(t, len(heights))
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	defer surface_result_destroy(&surfaces)
	region_hash, region_hash_ok := slicing.region_result_hash(
		{},
		topology,
		regions,
	)
	surface_hash, surface_hash_ok := surface_result_hash(
		region_hash,
		surfaces,
	)
	result, result_error := skins_propagate(
		topology,
		regions,
		surfaces,
		heights[:],
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			top = {600, 3},
			bottom = {600, 3},
		},
	)
	defer skin_result_destroy(&result)
	testing.expect(t, region_hash_ok)
	testing.expect(t, surface_hash_ok)
	testing.expect_value(t, result_error, Skin_Error.None)
	bytes, encode_error := skin_artifact_encode(
		surface_hash,
		Skin_Artifact_Test_Schedule_Hash,
		heights[:],
		regions,
		surfaces,
		result,
	)
	defer delete(bytes)
	testing.expect_value(t, encode_error, Skin_Artifact_Error.None)
	_, truncated_error := skin_artifact_decode(
		bytes[:len(bytes)-1],
		surface_hash,
		Skin_Artifact_Test_Schedule_Hash,
		regions,
		surfaces,
	)
	testing.expect_value(t, truncated_error, Skin_Artifact_Error.Malformed)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[0] = 0
	_, magic_error := skin_artifact_decode(
		corrupt,
		surface_hash,
		Skin_Artifact_Test_Schedule_Hash,
		regions,
		surfaces,
	)
	testing.expect_value(t, magic_error, Skin_Artifact_Error.Malformed)
	copy(corrupt, bytes)
	surface_artifact_put_u32(corrupt, 8, 2)
	_, version_error := skin_artifact_decode(
		corrupt,
		surface_hash,
		Skin_Artifact_Test_Schedule_Hash,
		regions,
		surfaces,
	)
	testing.expect_value(
		t,
		version_error,
		Skin_Artifact_Error.Unsupported_Version,
	)
	copy(corrupt, bytes)
	corrupt[145] = 1
	_, reserved_error := skin_artifact_decode(
		corrupt,
		surface_hash,
		Skin_Artifact_Test_Schedule_Hash,
		regions,
		surfaces,
	)
	testing.expect_value(t, reserved_error, Skin_Artifact_Error.Malformed)
	wrong_hash := surface_hash
	wrong_hash[0] = wrong_hash[0] ~ 1
	_, surface_dependency_error := skin_artifact_decode(
		bytes,
		wrong_hash,
		Skin_Artifact_Test_Schedule_Hash,
		regions,
		surfaces,
	)
	testing.expect_value(
		t,
		surface_dependency_error,
		Skin_Artifact_Error.Dependency_Mismatch,
	)
	wrong_hash = Skin_Artifact_Test_Schedule_Hash
	wrong_hash[0] = wrong_hash[0] ~ 1
	_, schedule_dependency_error := skin_artifact_decode(
		bytes,
		surface_hash,
		wrong_hash,
		regions,
		surfaces,
	)
	testing.expect_value(
		t,
		schedule_dependency_error,
		Skin_Artifact_Error.Dependency_Mismatch,
	)
	copy(corrupt, bytes)
	corrupt[112] = corrupt[112] ~ 1
	_, hash_error := skin_artifact_decode(
		corrupt,
		surface_hash,
		Skin_Artifact_Test_Schedule_Hash,
		regions,
		surfaces,
	)
	testing.expect_value(t, hash_error, Skin_Artifact_Error.Hash_Mismatch)
	mask_offset :=
		int(SKIN_ARTIFACT_HEADER_SIZE)+
		3*int(SKIN_ARTIFACT_LAYER_HEIGHT_SIZE)+
		3*int(SKIN_ARTIFACT_LAYER_SIZE)
	copy(corrupt, bytes)
	surface_artifact_put_u64(corrupt, mask_offset+8, 0)
	_, record_error := skin_artifact_decode(
		corrupt,
		surface_hash,
		Skin_Artifact_Test_Schedule_Hash,
		regions,
		surfaces,
	)
	testing.expect_value(t, record_error, Skin_Artifact_Error.Invalid_Record)
	source_offset :=
		mask_offset+
		3*int(SKIN_ARTIFACT_MASK_SIZE)+
		3*int(SKIN_ARTIFACT_PATH_SIZE)+
		12*int(SKIN_ARTIFACT_POINT_SIZE)
	copy(corrupt, bytes)
	corrupt[source_offset+5] = 1
	_, source_reserved_error := skin_artifact_decode(
		corrupt,
		surface_hash,
		Skin_Artifact_Test_Schedule_Hash,
		regions,
		surfaces,
	)
	testing.expect_value(
		t,
		source_reserved_error,
		Skin_Artifact_Error.Malformed,
	)
	limits := DEFAULT_SKIN_ARTIFACT_LIMITS
	limits.max_source_references = 5
	_, limit_error := skin_artifact_decode(
		bytes,
		surface_hash,
		Skin_Artifact_Test_Schedule_Hash,
		regions,
		surfaces,
		limits,
	)
	testing.expect_value(t, limit_error, Skin_Artifact_Error.Limit)
	_, overflow_ok := skin_artifact_byte_count(0, 0, 0, 0, max(u64))
	testing.expect(t, !overflow_ok)
	result.masks[0].region_id = contracts.INVALID_STABLE_ID
	_, invalid_encode_error := skin_artifact_encode(
		surface_hash,
		Skin_Artifact_Test_Schedule_Hash,
		heights[:],
		regions,
		surfaces,
		result,
	)
	testing.expect_value(
		t,
		invalid_encode_error,
		Skin_Artifact_Error.Invalid_Record,
	)
}

skin_artifact_test_bytes_equal :: proc(left, right: []u8) -> bool {
	if len(left) != len(right) {return false}
	for byte, byte_index in left {
		if byte != right[byte_index] {return false}
	}
	return true
}

Skin_Artifact_Test_Schedule_Hash :: contracts.Content_Hash{
	0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
	0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00,
	0x00, 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99,
	0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
}

Skin_Artifact_Test_Digest :: [sha2.DIGEST_SIZE_256]u8{
	0x1a, 0xde, 0xdc, 0x49, 0xf0, 0x9f, 0xcc, 0x1f,
	0xf0, 0x7d, 0x69, 0x7a, 0x35, 0x05, 0x52, 0x3f,
	0x93, 0xb8, 0xfe, 0x80, 0x80, 0xd6, 0x93, 0x71,
	0x4a, 0x0e, 0x9a, 0x13, 0x7c, 0x8b, 0x21, 0xe3,
}
