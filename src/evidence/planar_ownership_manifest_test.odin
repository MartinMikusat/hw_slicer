package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:testing"

import contracts "../contracts"
import slicing "../slicing"

@(test)
planar_ownership_manifest_binds_artifact_summary_and_result_test :: proc(
	t: ^testing.T,
) {
	result := planar_ownership_artifact_test_result()
	defer slicing.planar_ownership_destroy(&result)
	bytes, encode_error := planar_ownership_artifact_encode(
		PLANAR_OWNERSHIP_ARTIFACT_TEST_INTERSECTION_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Planar_Ownership_Artifact_Error.None,
	)
	capture, capture_error := planar_ownership_capture_describe(
		"planar-ownership.bin",
		{
			level = .Primitives,
			item_limit = 4,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer planar_ownership_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Planar_Ownership_Capture_Error.None,
	)
	decoded, decode_error := planar_ownership_artifact_decode(bytes)
	defer planar_ownership_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		Planar_Ownership_Artifact_Error.None,
	)
	result_hash_text := hex.encode(decoded.result_hash[:])
	defer delete(result_hash_text)
	provider, provider_ok := contracts.provider_descriptor_make(
		"cpu-planar-ownership",
		{0, 1, 0},
		.Intersect,
	)
	testing.expect(t, provider_ok)
	summary := [7]Evidence_Counter{
		{"ownership_layers", 2},
		{"owned_segments", 2},
		{"planar_incidences", 4},
		{"unresolved_groups", 1},
		{"suppressed_groups", 1},
		{"collapsed_incidences", 1},
		{"ownership_exact_predicates", 3},
	}
	invariants := [2]Evidence_Invariant{
		{
			"canonical_planar_ownership_result_hash",
			true,
			string(result_hash_text),
			string(result_hash_text),
		},
		{
			"source_independent_planar_ownership_replay",
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
				slicing.SCHEMA_VERSION_PLANAR_OWNERSHIP_HASH,
			revision = PLANAR_OWNERSHIP_MANIFEST_STAGE_REVISION,
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
		planar_ownership_manifest_preflight(
			manifest,
			"planar-ownership.bin",
			bytes,
		)
	testing.expect_value(
		t,
		preflight_error,
		Planar_Ownership_Manifest_Error.None,
	)
	testing.expect_value(
		t,
		planar_ownership_manifest_replay_verify(
			expectations,
			decoded,
		),
		Planar_Ownership_Manifest_Error.None,
	)
	summary[2].value = 5
	_, summary_error := planar_ownership_manifest_preflight(
		manifest,
		"planar-ownership.bin",
		bytes,
	)
	testing.expect_value(
		t,
		summary_error,
		Planar_Ownership_Manifest_Error.Summary_Mismatch,
	)
	summary[2].value = 4
	invariants[0].observed = GOLDEN_HASH
	_, invariant_error := planar_ownership_manifest_preflight(
		manifest,
		"planar-ownership.bin",
		bytes,
	)
	testing.expect_value(
		t,
		invariant_error,
		Planar_Ownership_Manifest_Error.Invariant_Mismatch,
	)
	invariants[0].observed = string(result_hash_text)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[72] = corrupt[72] ~ 1
	_, artifact_error := planar_ownership_manifest_preflight(
		manifest,
		"planar-ownership.bin",
		corrupt,
	)
	testing.expect_value(
		t,
		artifact_error,
		Planar_Ownership_Manifest_Error.Artifact_Hash_Mismatch,
	)
	expectations.layer_count = 3
	testing.expect_value(
		t,
		planar_ownership_manifest_replay_verify(
			expectations,
			decoded,
		),
		Planar_Ownership_Manifest_Error.Result_Mismatch,
	)
}
