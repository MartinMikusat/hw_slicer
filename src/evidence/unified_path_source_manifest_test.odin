package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:testing"

import contracts "../contracts"
import features "../features"

@(test)
unified_source_manifest_binds_artifact_summary_and_result_test :: proc(
	t: ^testing.T,
) {
	bytes := unified_path_source_capture_test_artifact(t)
	defer delete(bytes)
	capture, capture_error := unified_path_source_capture_describe(
		"unified-sources.bin",
		{
			level = .Primitives,
			item_limit = 1,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer unified_path_source_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Unified_Path_Source_Capture_Error.None,
	)
	decoded, decode_error :=
		features.unified_path_source_artifact_decode(bytes)
	defer features.unified_path_source_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		features.Unified_Path_Source_Artifact_Error.None,
	)
	result_hash_text := hex.encode(decoded.result_hash[:])
	defer delete(result_hash_text)
	provider, provider_ok := contracts.provider_descriptor_make(
		"cpu-unified-feature-sources",
		{0, 1, 0},
		.Generate_Features,
	)
	testing.expect(t, provider_ok)
	summary := [3]Evidence_Counter{
		{"feature_source_layers", 1},
		{"feature_sources", 0},
		{"feature_source_points", 0},
	}
	invariants := [2]Evidence_Invariant{
		{
			"canonical_unified_source_result_hash",
			true,
			string(result_hash_text),
			string(result_hash_text),
		},
		{
			"source_independent_unified_source_replay",
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
			schema_version =
				features.SCHEMA_VERSION_UNIFIED_PATH_SOURCE_HASH,
			revision =
				UNIFIED_PATH_SOURCE_MANIFEST_STAGE_REVISION,
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
		unified_path_source_manifest_preflight(
			manifest,
			"unified-sources.bin",
			bytes,
		)
	testing.expect_value(
		t,
		preflight_error,
		Unified_Path_Source_Manifest_Error.None,
	)
	testing.expect_value(
		t,
		unified_path_source_manifest_replay_verify(
			expectations,
			decoded,
		),
		Unified_Path_Source_Manifest_Error.None,
	)
	summary[0].value = 2
	_, summary_error := unified_path_source_manifest_preflight(
		manifest,
		"unified-sources.bin",
		bytes,
	)
	testing.expect_value(
		t,
		summary_error,
		Unified_Path_Source_Manifest_Error.Summary_Mismatch,
	)
	summary[0].value = 1
	invariants[0].observed = GOLDEN_HASH
	_, invariant_error := unified_path_source_manifest_preflight(
		manifest,
		"unified-sources.bin",
		bytes,
	)
	testing.expect_value(
		t,
		invariant_error,
		Unified_Path_Source_Manifest_Error.Invariant_Mismatch,
	)
	invariants[0].observed = string(result_hash_text)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[256] = corrupt[256] ~ 1
	_, artifact_error := unified_path_source_manifest_preflight(
		manifest,
		"unified-sources.bin",
		corrupt,
	)
	testing.expect_value(
		t,
		artifact_error,
		Unified_Path_Source_Manifest_Error.Artifact_Hash_Mismatch,
	)
	expectations.layer_count = 2
	testing.expect_value(
		t,
		unified_path_source_manifest_replay_verify(
			expectations,
			decoded,
		),
		Unified_Path_Source_Manifest_Error.Result_Mismatch,
	)
}
