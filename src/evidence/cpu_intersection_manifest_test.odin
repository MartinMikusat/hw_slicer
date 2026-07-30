package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:testing"

import contracts "../contracts"
import slicing "../slicing"

@(test)
cpu_intersection_manifest_binds_artifact_summary_and_result_test :: proc(
	t: ^testing.T,
) {
	result := cpu_intersection_artifact_test_result()
	defer slicing.cpu_intersections_destroy(&result)
	bytes, encode_error := cpu_intersection_artifact_encode(
		CPU_INTERSECTION_ARTIFACT_TEST_SPAN_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		CPU_Intersection_Artifact_Error.None,
	)
	capture, capture_error := cpu_intersection_capture_describe(
		"cpu-intersections.bin",
		{
			level = .Primitives,
			item_limit = 5,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer cpu_intersection_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		CPU_Intersection_Capture_Error.None,
	)
	decoded, decode_error := cpu_intersection_artifact_decode(bytes)
	defer cpu_intersection_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		CPU_Intersection_Artifact_Error.None,
	)
	result_hash_text := hex.encode(decoded.result_hash[:])
	defer delete(result_hash_text)
	provider, provider_ok := contracts.provider_descriptor_make(
		"cpu-triangle-intersections",
		{0, 1, 0},
		.Intersect,
	)
	testing.expect(t, provider_ok)
	summary := [6]Evidence_Counter{
		{"intersection_layers", 2},
		{"raw_segments", 1},
		{"planar_candidates", 2},
		{"tangent_pairs", 1},
		{"degenerate_pairs", 0},
		{"exact_predicates", 3},
	}
	invariants := [2]Evidence_Invariant{
		{
			"canonical_intersection_result_hash",
			true,
			string(result_hash_text),
			string(result_hash_text),
		},
		{
			"source_independent_intersection_replay",
			true,
			"passed",
			"passed",
		},
	}
	primitives := [1]Evidence_Artifact{capture.artifact}
	manifest := Evidence_Manifest{
		schema_version = contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		request_hash = GOLDEN_HASH,
		stage = {
			name = "intersect",
			schema_version =
				slicing.SCHEMA_VERSION_CPU_INTERSECTION_HASH,
			revision = CPU_INTERSECTION_MANIFEST_STAGE_REVISION,
		},
		provider = {
			id = fmt.tprintf("%016x", u64(provider.id)),
			name = provider.name,
			version = "0.1.0",
		},
		source_root_id = "8877665544332211",
		source_bounds = {units = "millimetre"},
		planar_bounds = {units = "micrometre"},
		summary = summary[:],
		invariants = invariants[:],
		primitives = primitives[:],
	}
	expectations, preflight_error :=
		cpu_intersection_manifest_preflight(
			manifest,
			"cpu-intersections.bin",
			bytes,
		)
	testing.expect_value(
		t,
		preflight_error,
		CPU_Intersection_Manifest_Error.None,
	)
	testing.expect_value(
		t,
		cpu_intersection_manifest_replay_verify(
			expectations,
			decoded,
		),
		CPU_Intersection_Manifest_Error.None,
	)
	summary[1].value = 2
	_, summary_error := cpu_intersection_manifest_preflight(
		manifest,
		"cpu-intersections.bin",
		bytes,
	)
	testing.expect_value(
		t,
		summary_error,
		CPU_Intersection_Manifest_Error.Summary_Mismatch,
	)
	summary[1].value = 1
	invariants[0].observed = GOLDEN_HASH
	_, invariant_error :=
		cpu_intersection_manifest_preflight(
			manifest,
			"cpu-intersections.bin",
			bytes,
		)
	testing.expect_value(
		t,
		invariant_error,
		CPU_Intersection_Manifest_Error.Invariant_Mismatch,
	)
	invariants[0].observed = string(result_hash_text)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[72] = corrupt[72] ~ 1
	_, artifact_error := cpu_intersection_manifest_preflight(
		manifest,
		"cpu-intersections.bin",
		corrupt,
	)
	testing.expect_value(
		t,
		artifact_error,
		CPU_Intersection_Manifest_Error.Artifact_Hash_Mismatch,
	)
	expectations.layer_count = 3
	testing.expect_value(
		t,
		cpu_intersection_manifest_replay_verify(
			expectations,
			decoded,
		),
		CPU_Intersection_Manifest_Error.Result_Mismatch,
	)
}
