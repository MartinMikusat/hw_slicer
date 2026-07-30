package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:testing"

import contracts "../contracts"
import slicing "../slicing"

@(test)
topology_manifest_binds_artifact_summary_hash_and_bounds_test :: proc(
	t: ^testing.T,
) {
	snapped_hash, source_segment_count, result :=
		topology_artifact_test_fixture()
	defer slicing.topology_result_destroy(&result)
	result_hash, result_hash_ok := slicing.topology_result_hash(
		snapped_hash,
		source_segment_count,
		result,
	)
	testing.expect(t, result_hash_ok)
	result_hash_text := hex.encode(result_hash[:])
	defer delete(result_hash_text)
	capture, capture_error := topology_capture_encode(
		"topology.bin",
		{
			level = .Primitives,
			item_limit = 39,
			byte_limit = 1_056,
		},
		{},
		snapped_hash,
		source_segment_count,
		result,
	)
	defer topology_capture_destroy(&capture)
	testing.expect_value(t, capture_error, Topology_Capture_Error.None)

	summary := [8]Evidence_Counter{
		{"layers", 1},
		{"vertices", 10},
		{"paths", 6},
		{"path_vertex_indices", 13},
		{"path_segment_indices", 9},
		{"open_chains", 4},
		{"degenerate_loops", 1},
		{"non_manifold_vertices", 1},
	}
	invariants := [2]Evidence_Invariant{
		{
			"canonical_result_hash",
			true,
			string(result_hash_text),
			string(result_hash_text),
		},
		{
			"source_independent_replay",
			true,
			"passed",
			"passed",
		},
	}
	primitives := [1]Evidence_Artifact{capture.artifact}
	provider := slicing.cpu_topology_provider_descriptor()
	manifest := Evidence_Manifest{
		schema_version = contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		request_hash =
			"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		stage = {
			name = "reconstruct-topology",
			schema_version = slicing.SCHEMA_VERSION_TOPOLOGY_HASH,
			revision = TOPOLOGY_MANIFEST_STAGE_REVISION,
		},
		provider = {
			id = fmt.tprintf("%016x", u64(provider.id)),
			name = slicing.CPU_TOPOLOGY_PROVIDER_NAME,
			version = "0.1.0",
		},
		source_root_id = "8877665544332211",
		source_bounds = {units = "millimetre"},
		planar_bounds = {
			valid = true,
			minimum = {0, 0},
			maximum = {11_000, 6_000},
			units = "micrometre",
		},
		summary = summary[:],
		invariants = invariants[:],
		primitives = primitives[:],
	}
	expectations, preflight_error := topology_manifest_preflight(
		manifest,
		"topology.bin",
		capture.bytes,
	)
	testing.expect_value(t, preflight_error, Topology_Manifest_Error.None)
	decoded, decode_error := topology_artifact_decode(capture.bytes)
	defer topology_artifact_destroy(&decoded)
	testing.expect_value(t, decode_error, Topology_Artifact_Error.None)
	testing.expect_value(
		t,
		topology_manifest_replay_verify(expectations, decoded),
		Topology_Manifest_Error.None,
	)

	summary[3].value = 12
	_, summary_error := topology_manifest_preflight(
		manifest,
		"topology.bin",
		capture.bytes,
	)
	testing.expect_value(
		t,
		summary_error,
		Topology_Manifest_Error.Summary_Mismatch,
	)
	summary[3].value = 13

	invariants[0].expected =
		"1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	_, invariant_error := topology_manifest_preflight(
		manifest,
		"topology.bin",
		capture.bytes,
	)
	testing.expect_value(
		t,
		invariant_error,
		Topology_Manifest_Error.Invariant_Mismatch,
	)
	invariants[0].expected = string(result_hash_text)

	corrupt := make([]u8, len(capture.bytes), context.temp_allocator)
	copy(corrupt, capture.bytes)
	corrupt[200] = corrupt[200] ~ 1
	_, artifact_error := topology_manifest_preflight(
		manifest,
		"topology.bin",
		corrupt,
	)
	testing.expect_value(
		t,
		artifact_error,
		Topology_Manifest_Error.Artifact_Hash_Mismatch,
	)

	expectations.bounds_maximum[0] += 1
	testing.expect_value(
		t,
		topology_manifest_replay_verify(expectations, decoded),
		Topology_Manifest_Error.Bounds_Mismatch,
	)
}
