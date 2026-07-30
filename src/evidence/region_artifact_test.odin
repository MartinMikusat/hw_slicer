package evidence

import "core:crypto/sha2"
import "core:mem"
import "core:testing"

import contracts "../contracts"
import geometry "../geometry"
import slicing "../slicing"

@(test)
region_artifact_round_trip_matches_golden_bytes_test :: proc(
	t: ^testing.T,
) {
	topology_hash, topology, regions := region_artifact_test_fixture()
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	bytes, encode_error := region_artifact_encode(
		topology_hash,
		topology,
		regions,
	)
	defer delete(bytes)
	artifact, decode_error := region_artifact_decode(
		bytes,
		topology_hash,
		topology,
	)
	defer region_artifact_destroy(&artifact)
	testing.expect_value(t, encode_error, Region_Artifact_Error.None)
	testing.expect_value(t, decode_error, Region_Artifact_Error.None)
	testing.expect_value(t, len(bytes), 548)
	testing.expect_value(t, artifact.topology_hash, topology_hash)
	testing.expect_value(t, len(artifact.result.layers), 1)
	testing.expect_value(t, len(artifact.result.contours), 3)
	testing.expect_value(t, len(artifact.result.regions), 2)
	testing.expect_value(
		t,
		len(artifact.result.region_contour_indices),
		3,
	)
	testing.expect_value(t, artifact.result.hole_count, u64(1))
	reencoded, reencode_error := region_artifact_encode(
		artifact.topology_hash,
		topology,
		artifact.result,
	)
	defer delete(reencoded)
	testing.expect_value(t, reencode_error, Region_Artifact_Error.None)
	testing.expect_value(t, string(reencoded), string(bytes))

	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, bytes)
	sha2.final(&hash_context, digest[:])
	expected_digest := [sha2.DIGEST_SIZE_256]u8{
		0xcf, 0xba, 0x9e, 0xe2, 0x57, 0xb9, 0x34, 0xdd,
		0xd9, 0xfb, 0xc9, 0x96, 0xcc, 0x14, 0x04, 0xda,
		0xa7, 0x19, 0x50, 0xf2, 0xbc, 0x8f, 0x07, 0x76,
		0x94, 0x8c, 0xbf, 0x5b, 0x22, 0x85, 0x7c, 0x0b,
	}
	testing.expect_value(t, digest, expected_digest)
}

@(test)
region_artifact_rejects_header_dependency_and_reserved_corruption_test :: proc(
	t: ^testing.T,
) {
	topology_hash, topology, regions := region_artifact_test_fixture()
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	bytes, encode_error :=
		region_artifact_encode(topology_hash, topology, regions)
	defer delete(bytes)
	testing.expect_value(t, encode_error, Region_Artifact_Error.None)
	testing.expect_value(
		t,
		region_artifact_test_decode_error(
			bytes[:len(bytes)-1],
			topology_hash,
			topology,
		),
		Region_Artifact_Error.Malformed,
	)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[0] = corrupt[0] ~ 1
	testing.expect_value(
		t,
		region_artifact_test_decode_error(corrupt, topology_hash, topology),
		Region_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	topology_artifact_put_u32(corrupt, 8, 2)
	testing.expect_value(
		t,
		region_artifact_test_decode_error(corrupt, topology_hash, topology),
		Region_Artifact_Error.Unsupported_Version,
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
			region_artifact_test_decode_error(
				corrupt,
				topology_hash,
				topology,
			),
			Region_Artifact_Error.Malformed,
		)
	}
	dependency_hash := topology_hash
	dependency_hash[0] = dependency_hash[0] ~ 1
	testing.expect_value(
		t,
		region_artifact_test_decode_error(
			bytes,
			dependency_hash,
			topology,
		),
		Region_Artifact_Error.Dependency_Mismatch,
	)
	contour_offset := int(REGION_ARTIFACT_HEADER_SIZE)+
		int(REGION_ARTIFACT_LAYER_SIZE)
	region_offset := contour_offset+
		int(REGION_ARTIFACT_CONTOUR_SIZE)*3
	reserved_ranges := [3][2]int{
		{136, 160},
		{contour_offset+26, contour_offset+32},
		{region_offset+28, region_offset+32},
	}
	for reserved_range in reserved_ranges {
		for byte_offset in reserved_range[0]..<reserved_range[1] {
			copy(corrupt, bytes)
			corrupt[byte_offset] = 1
			testing.expect_value(
				t,
				region_artifact_test_decode_error(
					corrupt,
					topology_hash,
					topology,
				),
				Region_Artifact_Error.Malformed,
			)
		}
	}
}

@(test)
region_artifact_rejects_records_membership_and_hash_corruption_test :: proc(
	t: ^testing.T,
) {
	topology_hash, topology, regions := region_artifact_test_fixture()
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	bytes, encode_error :=
		region_artifact_encode(topology_hash, topology, regions)
	defer delete(bytes)
	testing.expect_value(t, encode_error, Region_Artifact_Error.None)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	contour_offset := int(REGION_ARTIFACT_HEADER_SIZE)+
		int(REGION_ARTIFACT_LAYER_SIZE)
	region_offset := contour_offset+
		int(REGION_ARTIFACT_CONTOUR_SIZE)*3
	index_offset := region_offset+int(REGION_ARTIFACT_REGION_SIZE)*2

	copy(corrupt, bytes)
	corrupt[contour_offset+24] = 3
	testing.expect_value(
		t,
		region_artifact_test_decode_error(corrupt, topology_hash, topology),
		Region_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	corrupt[contour_offset+25] = 2
	testing.expect_value(
		t,
		region_artifact_test_decode_error(corrupt, topology_hash, topology),
		Region_Artifact_Error.Malformed,
	)
	copy(corrupt, bytes)
	topology_artifact_put_u32(corrupt, contour_offset+8, 99)
	testing.expect_value(
		t,
		region_artifact_test_decode_error(corrupt, topology_hash, topology),
		Region_Artifact_Error.Invalid_Record,
	)
	copy(corrupt, bytes)
	topology_artifact_put_u32(corrupt, index_offset, 2)
	testing.expect_value(
		t,
		region_artifact_test_decode_error(corrupt, topology_hash, topology),
		Region_Artifact_Error.Invalid_Record,
	)
	copy(corrupt, bytes)
	corrupt[64] = corrupt[64] ~ 1
	testing.expect_value(
		t,
		region_artifact_test_decode_error(corrupt, topology_hash, topology),
		Region_Artifact_Error.Hash_Mismatch,
	)
}

@(test)
region_artifact_enforces_limits_capture_and_allocation_failure_test :: proc(
	t: ^testing.T,
) {
	topology_hash, topology, regions := region_artifact_test_fixture()
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	bytes, encode_error :=
		region_artifact_encode(topology_hash, topology, regions)
	defer delete(bytes)
	testing.expect_value(t, encode_error, Region_Artifact_Error.None)
	limits := DEFAULT_REGION_ARTIFACT_LIMITS
	limits.max_contours = 2
	_, limited_encode_error := region_artifact_encode(
		topology_hash,
		topology,
		regions,
		limits,
	)
	testing.expect_value(
		t,
		limited_encode_error,
		Region_Artifact_Error.Limit,
	)
	_, limited_decode_error := region_artifact_decode(
		bytes,
		topology_hash,
		topology,
		limits,
	)
	testing.expect_value(
		t,
		limited_decode_error,
		Region_Artifact_Error.Limit,
	)
	_, allocation_error := region_artifact_decode(
		bytes,
		topology_hash,
		topology,
		DEFAULT_REGION_ARTIFACT_LIMITS,
		mem.nil_allocator(),
	)
	testing.expect_value(
		t,
		allocation_error,
		Region_Artifact_Error.Allocation_Failed,
	)
	_, overflow_ok := region_artifact_byte_count(max(u64), 0, 0, 0)
	testing.expect(t, !overflow_ok)

	capture, capture_error := region_capture_encode(
		"stages/08-calculate-regions/primitives/regions.bin",
		{
			level = .Primitives,
			item_limit = 9,
			byte_limit = 548,
		},
		{},
		topology_hash,
		topology,
		regions,
	)
	defer region_capture_destroy(&capture)
	testing.expect_value(t, capture_error, Region_Capture_Error.None)
	testing.expect_value(t, capture.additional.item_count, u64(9))
	testing.expect_value(t, capture.additional.byte_count, u64(548))
	testing.expect_value(
		t,
		capture.artifact.format,
		REGION_ARTIFACT_FORMAT,
	)
}

region_artifact_test_decode_error :: proc(
	bytes: []u8,
	topology_hash: contracts.Content_Hash,
	topology: slicing.Topology_Result,
) -> Region_Artifact_Error {
	artifact, error := region_artifact_decode(
		bytes,
		topology_hash,
		topology,
	)
	region_artifact_destroy(&artifact)
	return error
}

region_artifact_test_fixture :: proc() -> (
	topology_hash: contracts.Content_Hash,
	topology: slicing.Topology_Result,
	regions: slicing.Region_Result,
) {
	snapped_hash: contracts.Content_Hash
	for &byte, byte_index in snapped_hash {
		byte = u8(0x80+byte_index)
	}
	points := [12]slicing.Snapped_Point{
		{0, 0},
		{100, 0},
		{100, 100},
		{0, 100},
		{20, 20},
		{80, 20},
		{80, 80},
		{20, 80},
		{40, 40},
		{60, 40},
		{60, 60},
		{40, 60},
	}
	paths := [3]slicing.Topology_Path{
		{
			id = 100,
			layer_index = 0,
			kind = .Loop,
			vertex_offset = 0,
			vertex_count = 4,
			segment_offset = 0,
			segment_count = 4,
			signed_area_2 = 20_000,
			winding = geometry.Predicate_Sign.Positive,
		},
		{
			id = 101,
			layer_index = 0,
			kind = .Loop,
			vertex_offset = 4,
			vertex_count = 4,
			segment_offset = 4,
			segment_count = 4,
			signed_area_2 = 7_200,
			winding = geometry.Predicate_Sign.Positive,
		},
		{
			id = 102,
			layer_index = 0,
			kind = .Loop,
			vertex_offset = 8,
			vertex_count = 4,
			segment_offset = 8,
			segment_count = 4,
			signed_area_2 = 800,
			winding = geometry.Predicate_Sign.Positive,
		},
	}
	topology.layers = make([]slicing.Topology_Layer, 1)
	topology.vertices = make([]slicing.Topology_Vertex, len(points))
	topology.paths = make([]slicing.Topology_Path, len(paths))
	topology.path_vertex_indices = make([]u32, len(points))
	topology.path_segment_indices = make([]u32, len(points))
	topology.layers[0] = {0, 12, 0, 3}
	copy(topology.paths, paths[:])
	for point, point_index in points {
		topology.vertices[point_index] = {
			id = contracts.Stable_ID(point_index+1),
			layer_index = 0,
			point = point,
			degree = 2,
		}
		topology.path_vertex_indices[point_index] = u32(point_index)
		topology.path_segment_indices[point_index] = u32(point_index)
	}
	topology_hash_ok: bool
	topology_hash, topology_hash_ok = slicing.topology_result_hash(
		snapped_hash,
		len(points),
		topology,
	)
	assert(topology_hash_ok)
	region_error: slicing.Region_Error
	regions, region_error = slicing.regions_build(topology)
	assert(region_error == .None)
	return
}
