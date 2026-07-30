package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:testing"

import contracts "../contracts"
import features "../features"

@(test)
perimeter_manifest_binds_artifact_summary_and_result_test :: proc(
	t: ^testing.T,
) {
	bytes := perimeter_capture_test_artifact(t)
	defer delete(bytes)
	capture, capture_error := perimeter_capture_describe(
		"perimeters.bin",
		{
			level = .Primitives,
			item_limit = 1,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer perimeter_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Perimeter_Capture_Error.None,
	)
	decoded, decode_error :=
		features.perimeter_artifact_decode(bytes)
	defer features.perimeter_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		features.Perimeter_Artifact_Error.None,
	)
	result_hash_text := hex.encode(decoded.result_hash[:])
	defer delete(result_hash_text)
	provider, provider_ok := contracts.provider_descriptor_make(
		"cpu-perimeters",
		{0, 1, 0},
		.Generate_Features,
	)
	testing.expect(t, provider_ok)
	summary := [4]Evidence_Counter{
		{"perimeter_layers", 1},
		{"perimeter_groups", 0},
		{"perimeter_paths", 0},
		{"perimeter_points", 0},
	}
	invariants := [2]Evidence_Invariant{
		{
			"canonical_perimeter_result_hash",
			true,
			string(result_hash_text),
			string(result_hash_text),
		},
		{
			"source_independent_perimeter_replay",
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
			name = "generate-features",
			schema_version = features.SCHEMA_VERSION_PERIMETER_HASH,
			revision = PERIMETER_MANIFEST_STAGE_REVISION,
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
	expectations, preflight_error := perimeter_manifest_preflight(
		manifest,
		"perimeters.bin",
		bytes,
	)
	testing.expect_value(
		t,
		preflight_error,
		Perimeter_Manifest_Error.None,
	)
	testing.expect_value(
		t,
		perimeter_manifest_replay_verify(expectations, decoded),
		Perimeter_Manifest_Error.None,
	)
	summary[0].value = 2
	_, summary_error := perimeter_manifest_preflight(
		manifest,
		"perimeters.bin",
		bytes,
	)
	testing.expect_value(
		t,
		summary_error,
		Perimeter_Manifest_Error.Summary_Mismatch,
	)
	summary[0].value = 1
	invariants[0].observed = GOLDEN_HASH
	_, invariant_error := perimeter_manifest_preflight(
		manifest,
		"perimeters.bin",
		bytes,
	)
	testing.expect_value(
		t,
		invariant_error,
		Perimeter_Manifest_Error.Invariant_Mismatch,
	)
	invariants[0].observed = string(result_hash_text)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[72] = corrupt[72] ~ 1
	_, artifact_error := perimeter_manifest_preflight(
		manifest,
		"perimeters.bin",
		corrupt,
	)
	testing.expect_value(
		t,
		artifact_error,
		Perimeter_Manifest_Error.Artifact_Hash_Mismatch,
	)
	expectations.layer_count = 2
	testing.expect_value(
		t,
		perimeter_manifest_replay_verify(expectations, decoded),
		Perimeter_Manifest_Error.Result_Mismatch,
	)
}
