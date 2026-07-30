package evidence

import "core:crypto/sha2"
import "core:mem"
import "core:testing"

import contracts "../contracts"
import geometry "../geometry"
import slicing "../slicing"

@(test)
topology_artifact_round_trip_matches_golden_bytes_test :: proc(
	t: ^testing.T,
) {
	snapped_hash, source_segment_count, result :=
		topology_artifact_test_fixture()
	defer slicing.topology_result_destroy(&result)
	bytes, encode_error := topology_artifact_encode(
		snapped_hash,
		source_segment_count,
		result,
	)
	defer delete(bytes)
	artifact, decode_error := topology_artifact_decode(bytes)
	defer topology_artifact_destroy(&artifact)
	testing.expect_value(t, encode_error, Topology_Artifact_Error.None)
	testing.expect_value(t, decode_error, Topology_Artifact_Error.None)
	testing.expect_value(t, len(bytes), 1_056)
	testing.expect_value(t, artifact.snapped_hash, snapped_hash)
	testing.expect_value(
		t,
		artifact.source_segment_count,
		u64(source_segment_count),
	)
	testing.expect_value(t, len(artifact.result.layers), 1)
	testing.expect_value(t, len(artifact.result.vertices), 10)
	testing.expect_value(t, len(artifact.result.paths), 6)
	testing.expect_value(t, artifact.result.open_chain_count, u64(4))
	testing.expect_value(
		t,
		artifact.result.degenerate_loop_count,
		u64(1),
	)
	testing.expect_value(
		t,
		artifact.result.non_manifold_vertex_count,
		u64(1),
	)
	regions, region_error := slicing.regions_build(artifact.result)
	defer slicing.region_result_destroy(&regions)
	testing.expect_value(t, region_error, slicing.Region_Error.None)
	region_hash, region_hash_ok := slicing.region_result_hash(
		artifact.result_hash,
		artifact.result,
		regions,
	)
	testing.expect(t, region_hash_ok)
	expected_region_hash := contracts.Content_Hash{
		0x02, 0x81, 0x63, 0xb0, 0xba, 0xfd, 0xe7, 0x73,
		0x62, 0x7e, 0xaf, 0xa6, 0xef, 0xab, 0x77, 0x1b,
		0x1e, 0x28, 0x1c, 0xb5, 0x8d, 0xbe, 0x3e, 0xa1,
		0xbf, 0x57, 0xde, 0x20, 0x7a, 0x7b, 0x3d, 0x21,
	}
	testing.expect_value(t, region_hash, expected_region_hash)
	reencoded, reencode_error := topology_artifact_encode(
		artifact.snapped_hash,
		int(artifact.source_segment_count),
		artifact.result,
	)
	defer delete(reencoded)
	testing.expect_value(
		t,
		reencode_error,
		Topology_Artifact_Error.None,
	)
	testing.expect_value(t, string(reencoded), string(bytes))

	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	expected_digest := [sha2.DIGEST_SIZE_256]u8{
		0x27, 0x26, 0xf6, 0xe7, 0xd2, 0x8c, 0x1c, 0xcf,
		0x06, 0x90, 0xad, 0xa3, 0xef, 0xa7, 0x78, 0x06,
		0x7e, 0x87, 0x16, 0x5b, 0x2c, 0x34, 0x56, 0x31,
		0x13, 0x69, 0x68, 0x5e, 0x0f, 0xa1, 0x38, 0x8a,
	}
	testing.expect_value(t, digest, expected_digest)
}

@(test)
topology_artifact_rejects_header_and_reserved_corruption_test :: proc(
	t: ^testing.T,
) {
	snapped_hash, source_segment_count, result :=
		topology_artifact_test_fixture()
	defer slicing.topology_result_destroy(&result)
	bytes, encode_error := topology_artifact_encode(
		snapped_hash,
		source_segment_count,
		result,
	)
	defer delete(bytes)
	testing.expect_value(t, encode_error, Topology_Artifact_Error.None)
	testing.expect_value(
		t,
		topology_artifact_test_decode_error(bytes[:len(bytes)-1]),
		Topology_Artifact_Error.Malformed,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[0] = corrupt[0] ~ 1
	testing.expect_value(
		t,
		topology_artifact_test_decode_error(corrupt),
		Topology_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	topology_artifact_put_u32(corrupt, 8, 2)
	testing.expect_value(
		t,
		topology_artifact_test_decode_error(corrupt),
		Topology_Artifact_Error.Unsupported_Version,
	)
	size_offsets := [5]int{12, 16, 20, 24, 28}
	for size_offset in size_offsets {
		copy(corrupt, bytes)
		topology_artifact_put_u32(
			corrupt,
			size_offset,
			topology_artifact_get_u32(corrupt, size_offset)+1,
		)
		testing.expect_value(
			t,
			topology_artifact_test_decode_error(corrupt),
			Topology_Artifact_Error.Malformed,
		)
	}
	path_offset := int(TOPOLOGY_ARTIFACT_HEADER_SIZE)+
		int(TOPOLOGY_ARTIFACT_LAYER_SIZE)+
		int(TOPOLOGY_ARTIFACT_VERTEX_SIZE)*10
	reserved_ranges := [5][2]int{
		{168, 192},
		{path_offset+13, path_offset+16},
		{path_offset+28, path_offset+32},
		{path_offset+44, path_offset+48},
		{path_offset+65, path_offset+72},
	}
	for reserved_range in reserved_ranges {
		for byte_offset in reserved_range[0]..<reserved_range[1] {
			copy(corrupt, bytes)
			corrupt[byte_offset] = 1
			testing.expect_value(
				t,
				topology_artifact_test_decode_error(corrupt),
				Topology_Artifact_Error.Malformed,
			)
		}
	}
}

@(test)
topology_artifact_rejects_spans_indices_counters_and_hashes_test :: proc(
	t: ^testing.T,
) {
	snapped_hash, source_segment_count, result :=
		topology_artifact_test_fixture()
	defer slicing.topology_result_destroy(&result)
	bytes, encode_error := topology_artifact_encode(
		snapped_hash,
		source_segment_count,
		result,
	)
	defer delete(bytes)
	testing.expect_value(t, encode_error, Topology_Artifact_Error.None)
	corrupt := make([]u8, len(bytes), context.temp_allocator)

	copy(corrupt, bytes)
	topology_artifact_put_u64(corrupt, 144, 3)
	testing.expect_value(
		t,
		topology_artifact_test_decode_error(corrupt),
		Topology_Artifact_Error.Invalid_Record,
	)
	copy(corrupt, bytes)
	topology_artifact_put_u64(
		corrupt,
		int(TOPOLOGY_ARTIFACT_HEADER_SIZE),
		1,
	)
	testing.expect_value(
		t,
		topology_artifact_test_decode_error(corrupt),
		Topology_Artifact_Error.Invalid_Record,
	)
	path_vertex_offset := int(TOPOLOGY_ARTIFACT_HEADER_SIZE)+
		int(TOPOLOGY_ARTIFACT_LAYER_SIZE)+
		int(TOPOLOGY_ARTIFACT_VERTEX_SIZE)*10+
		int(TOPOLOGY_ARTIFACT_PATH_SIZE)*6
	copy(corrupt, bytes)
	topology_artifact_put_u32(corrupt, path_vertex_offset, 10)
	testing.expect_value(
		t,
		topology_artifact_test_decode_error(corrupt),
		Topology_Artifact_Error.Invalid_Record,
	)
	path_segment_offset := path_vertex_offset+
		int(TOPOLOGY_ARTIFACT_INDEX_SIZE)*13
	copy(corrupt, bytes)
	topology_artifact_put_u32(
		corrupt,
		path_segment_offset+int(TOPOLOGY_ARTIFACT_INDEX_SIZE)*8,
		0,
	)
	testing.expect_value(
		t,
		topology_artifact_test_decode_error(corrupt),
		Topology_Artifact_Error.Invalid_Record,
	)
	copy(corrupt, bytes)
	corrupt[64] = corrupt[64] ~ 1
	testing.expect_value(
		t,
		topology_artifact_test_decode_error(corrupt),
		Topology_Artifact_Error.Hash_Mismatch,
	)
	copy(corrupt, bytes)
	first_path_offset := int(TOPOLOGY_ARTIFACT_HEADER_SIZE)+
		int(TOPOLOGY_ARTIFACT_LAYER_SIZE)+
		int(TOPOLOGY_ARTIFACT_VERTEX_SIZE)*10
	copy(corrupt, bytes)
	corrupt[first_path_offset+12] = 4
	testing.expect_value(
		t,
		topology_artifact_test_decode_error(corrupt),
		Topology_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	corrupt[first_path_offset+48] =
		corrupt[first_path_offset+48] ~ 1
	testing.expect_value(
		t,
		topology_artifact_test_decode_error(corrupt),
		Topology_Artifact_Error.Invalid_Record,
	)
}

@(test)
topology_artifact_enforces_limits_and_allocation_failure_test :: proc(
	t: ^testing.T,
) {
	snapped_hash, source_segment_count, result :=
		topology_artifact_test_fixture()
	defer slicing.topology_result_destroy(&result)
	bytes, encode_error := topology_artifact_encode(
		snapped_hash,
		source_segment_count,
		result,
	)
	defer delete(bytes)
	testing.expect_value(t, encode_error, Topology_Artifact_Error.None)
	limits := DEFAULT_TOPOLOGY_ARTIFACT_LIMITS
	limits.max_vertices = 9
	_, limited_encode_error := topology_artifact_encode(
		snapped_hash,
		source_segment_count,
		result,
		limits,
	)
	testing.expect_value(
		t,
		limited_encode_error,
		Topology_Artifact_Error.Limit,
	)
	_, limited_decode_error := topology_artifact_decode(bytes, limits)
	testing.expect_value(
		t,
		limited_decode_error,
		Topology_Artifact_Error.Limit,
	)
	limits = DEFAULT_TOPOLOGY_ARTIFACT_LIMITS
	limits.max_bytes = u64(len(bytes)-1)
	_, byte_limit_error := topology_artifact_decode(bytes, limits)
	testing.expect_value(
		t,
		byte_limit_error,
		Topology_Artifact_Error.Limit,
	)
	_, allocation_error := topology_artifact_decode(
		bytes,
		DEFAULT_TOPOLOGY_ARTIFACT_LIMITS,
		mem.nil_allocator(),
	)
	testing.expect_value(
		t,
		allocation_error,
		Topology_Artifact_Error.Allocation_Failed,
	)
	_, overflow_ok := topology_artifact_byte_count(max(u64), 0, 0, 0, 0)
	testing.expect(t, !overflow_ok)
}

@(test)
topology_capture_preflights_and_describes_artifact_test :: proc(
	t: ^testing.T,
) {
	snapped_hash, source_segment_count, result :=
		topology_artifact_test_fixture()
	defer slicing.topology_result_destroy(&result)
	request := contracts.Evidence_Request{
		level = .Primitives,
		item_limit = 39,
		byte_limit = 1_056,
	}
	capture, capture_error := topology_capture_encode(
		"stages/07-reconstruct-topology/primitives/topology.bin",
		request,
		{},
		snapped_hash,
		source_segment_count,
		result,
	)
	defer topology_capture_destroy(&capture)
	testing.expect_value(t, capture_error, Topology_Capture_Error.None)
	testing.expect_value(t, capture.additional.item_count, u64(39))
	testing.expect_value(t, capture.additional.byte_count, u64(1_056))
	testing.expect_value(
		t,
		capture.artifact.format,
		TOPOLOGY_ARTIFACT_FORMAT,
	)
	testing.expect_value(
		t,
		capture.artifact.schema_version,
		TOPOLOGY_ARTIFACT_SCHEMA_VERSION,
	)
	request.level = .Summary
	_, level_error := topology_capture_encode(
		capture.artifact.path,
		request,
		{},
		snapped_hash,
		source_segment_count,
		result,
	)
	testing.expect_value(
		t,
		level_error,
		Topology_Capture_Error.Level_Insufficient,
	)
	request.level = .Primitives
	request.byte_limit = 1_055
	_, budget_error := topology_capture_encode(
		capture.artifact.path,
		request,
		{},
		snapped_hash,
		source_segment_count,
		result,
	)
	testing.expect_value(
		t,
		budget_error,
		Topology_Capture_Error.Byte_Limit,
	)
}

topology_artifact_test_decode_error :: proc(
	bytes: []u8,
) -> Topology_Artifact_Error {
	artifact, error := topology_artifact_decode(bytes)
	topology_artifact_destroy(&artifact)
	return error
}

topology_artifact_test_fixture :: proc() -> (
	snapped_hash: contracts.Content_Hash,
	source_segment_count: int,
	result: slicing.Topology_Result,
) {
	for &byte, byte_index in snapped_hash {
		byte = u8(0x40+byte_index)
	}
	result.layers = make([]slicing.Topology_Layer, 1)
	result.vertices = make([]slicing.Topology_Vertex, 10)
	result.paths = make([]slicing.Topology_Path, 6)
	result.path_vertex_indices = make([]u32, 13)
	result.path_segment_indices = make([]u32, 9)
	result.layers[0] = {0, 10, 0, 6}
	points := [10]slicing.Snapped_Point{
		{0, 0},
		{1000, 0},
		{0, 1000},
		{5000, 5000},
		{4000, 5000},
		{6000, 5000},
		{5000, 4000},
		{5000, 6000},
		{10000, 0},
		{11000, 0},
	}
	degrees := [10]u32{2, 2, 2, 4, 1, 1, 1, 1, 2, 2}
	for &vertex, vertex_index in result.vertices {
		vertex = {
			id = contracts.Stable_ID(0x100+vertex_index),
			layer_index = 0,
			point = points[vertex_index],
			degree = degrees[vertex_index],
		}
	}
	result.paths[0] = {
		id = 0x200,
		layer_index = 0,
		kind = .Loop,
		vertex_offset = 0,
		vertex_count = 3,
		segment_offset = 0,
		segment_count = 3,
		signed_area_2 = 1_000_000,
		winding = geometry.Predicate_Sign.Positive,
	}
	for path_index in 0..<4 {
		result.paths[path_index+1] = {
			id = contracts.Stable_ID(0x201+path_index),
			layer_index = 0,
			kind = .Open_Chain,
			vertex_offset = u64(3+path_index*2),
			vertex_count = 2,
			segment_offset = u64(3+path_index),
			segment_count = 1,
			winding = .Zero,
		}
	}
	result.paths[5] = {
		id = 0x205,
		layer_index = 0,
		kind = .Degenerate_Loop,
		vertex_offset = 11,
		vertex_count = 2,
		segment_offset = 7,
		segment_count = 2,
		winding = .Zero,
	}
	path_vertex_indices := [13]u32{
		0, 1, 2,
		3, 4,
		3, 5,
		3, 6,
		3, 7,
		8, 9,
	}
	copy(result.path_vertex_indices, path_vertex_indices[:])
	for &segment_index, index in result.path_segment_indices {
		segment_index = u32(index)
	}
	result.open_chain_count = 4
	result.degenerate_loop_count = 1
	result.non_manifold_vertex_count = 1
	source_segment_count = 9
	return
}
