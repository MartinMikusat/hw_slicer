package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:testing"

import contracts "../contracts"
import features "../features"

@(test)
surface_manifest_binds_artifact_summary_and_result_test :: proc(
	t: ^testing.T,
) {
	bytes := surface_capture_test_artifact(t)
	defer delete(bytes)
	capture, capture_error := surface_capture_describe(
		"surfaces.bin",
		{
			level = .Primitives,
			item_limit = 1,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer surface_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Surface_Capture_Error.None,
	)
	decoded, decode_error :=
		features.surface_artifact_decode(bytes)
	defer features.surface_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		features.Surface_Artifact_Error.None,
	)
	result_hash_text := hex.encode(decoded.result_hash[:])
	defer delete(result_hash_text)
	provider, provider_ok := contracts.provider_descriptor_make(
		"cpu-exposed-surfaces",
		{0, 1, 0},
		.Generate_Features,
	)
	testing.expect(t, provider_ok)
	summary := [6]Evidence_Counter{
		{"surface_layers", 1},
		{"surface_masks", 0},
		{"surface_paths", 0},
		{"surface_points", 0},
		{"surface_bottom_masks", 0},
		{"surface_top_masks", 0},
	}
	invariants := [2]Evidence_Invariant{
		{
			"canonical_surface_result_hash",
			true,
			string(result_hash_text),
			string(result_hash_text),
		},
		{
			"source_independent_surface_replay",
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
			schema_version = features.SCHEMA_VERSION_SURFACE_HASH,
			revision = SURFACE_MANIFEST_STAGE_REVISION,
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
	expectations, preflight_error := surface_manifest_preflight(
		manifest,
		"surfaces.bin",
		bytes,
	)
	testing.expect_value(
		t,
		preflight_error,
		Surface_Manifest_Error.None,
	)
	testing.expect_value(
		t,
		surface_manifest_replay_verify(expectations, decoded),
		Surface_Manifest_Error.None,
	)
	summary[0].value = 2
	_, summary_error := surface_manifest_preflight(
		manifest,
		"surfaces.bin",
		bytes,
	)
	testing.expect_value(
		t,
		summary_error,
		Surface_Manifest_Error.Summary_Mismatch,
	)
	summary[0].value = 1
	invariants[0].observed = GOLDEN_HASH
	_, invariant_error := surface_manifest_preflight(
		manifest,
		"surfaces.bin",
		bytes,
	)
	testing.expect_value(
		t,
		invariant_error,
		Surface_Manifest_Error.Invariant_Mismatch,
	)
	invariants[0].observed = string(result_hash_text)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[72] = corrupt[72] ~ 1
	_, artifact_error := surface_manifest_preflight(
		manifest,
		"surfaces.bin",
		corrupt,
	)
	testing.expect_value(
		t,
		artifact_error,
		Surface_Manifest_Error.Artifact_Hash_Mismatch,
	)
	expectations.layer_count = 2
	testing.expect_value(
		t,
		surface_manifest_replay_verify(expectations, decoded),
		Surface_Manifest_Error.Result_Mismatch,
	)
}
