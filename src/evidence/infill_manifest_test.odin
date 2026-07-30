package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:testing"

import contracts "../contracts"
import features "../features"

@(test)
infill_manifest_binds_artifact_summary_and_result_test :: proc(
	t: ^testing.T,
) {
	bytes := infill_capture_test_artifact(t)
	defer delete(bytes)
	capture, capture_error := infill_capture_describe(
		"infill.bin",
		{
			level = .Primitives,
			item_limit = 1,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer infill_capture_destroy(&capture)
	testing.expect_value(t, capture_error, Infill_Capture_Error.None)
	decoded, decode_error := features.infill_artifact_decode(bytes)
	defer features.infill_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		features.Infill_Artifact_Error.None,
	)
	result_hash_text := hex.encode(decoded.result_hash[:])
	defer delete(result_hash_text)
	provider, provider_ok := contracts.provider_descriptor_make(
		"cpu-rectilinear-infill",
		{0, 1, 0},
		.Generate_Features,
	)
	testing.expect(t, provider_ok)
	summary := [4]Evidence_Counter{
		{"infill_layers", 1},
		{"infill_segments", 0},
		{"infill_boundary_hits", 0},
		{"infill_scanlines", 0},
	}
	invariants := [2]Evidence_Invariant{
		{
			"canonical_infill_result_hash",
			true,
			string(result_hash_text),
			string(result_hash_text),
		},
		{
			"source_independent_infill_replay",
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
			schema_version = features.SCHEMA_VERSION_INFILL_HASH,
			revision = INFILL_MANIFEST_STAGE_REVISION,
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
	expectations, preflight_error := infill_manifest_preflight(
		manifest,
		"infill.bin",
		bytes,
	)
	testing.expect_value(
		t,
		preflight_error,
		Infill_Manifest_Error.None,
	)
	testing.expect_value(
		t,
		infill_manifest_replay_verify(expectations, decoded),
		Infill_Manifest_Error.None,
	)
	summary[0].value = 2
	_, summary_error := infill_manifest_preflight(
		manifest,
		"infill.bin",
		bytes,
	)
	testing.expect_value(
		t,
		summary_error,
		Infill_Manifest_Error.Summary_Mismatch,
	)
	summary[0].value = 1
	invariants[0].observed = GOLDEN_HASH
	_, invariant_error := infill_manifest_preflight(
		manifest,
		"infill.bin",
		bytes,
	)
	testing.expect_value(
		t,
		invariant_error,
		Infill_Manifest_Error.Invariant_Mismatch,
	)
	invariants[0].observed = string(result_hash_text)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[64] = corrupt[64] ~ 1
	_, artifact_error := infill_manifest_preflight(
		manifest,
		"infill.bin",
		corrupt,
	)
	testing.expect_value(
		t,
		artifact_error,
		Infill_Manifest_Error.Artifact_Hash_Mismatch,
	)
	expectations.layer_count = 2
	testing.expect_value(
		t,
		infill_manifest_replay_verify(expectations, decoded),
		Infill_Manifest_Error.Result_Mismatch,
	)
}
