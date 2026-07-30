package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:testing"

import contracts "../contracts"
import features "../features"

@(test)
extrusion_manifest_binds_artifact_summary_and_result_test :: proc(
	t: ^testing.T,
) {
	bytes := extrusion_capture_test_artifact(t)
	defer delete(bytes)
	capture, capture_error := extrusion_capture_describe(
		"extrusion.bin",
		{
			level = .Primitives,
			item_limit = 1,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer extrusion_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Extrusion_Capture_Error.None,
	)
	decoded, decode_error := features.extrusion_artifact_decode(bytes)
	defer features.extrusion_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		features.Extrusion_Artifact_Error.None,
	)
	result_hash_text := hex.encode(decoded.result_hash[:])
	defer delete(result_hash_text)
	provider, provider_ok := contracts.provider_descriptor_make(
		"cpu-extrusion",
		{0, 1, 0},
		.Plan_Paths,
	)
	testing.expect(t, provider_ok)
	summary := [3]Evidence_Counter{
		{"extrusion_layers", 1},
		{"extrusion_moves", 0},
		{"extrusion_volume_cubic_um", 0},
	}
	invariants := [2]Evidence_Invariant{
		{
			"canonical_extrusion_result_hash",
			true,
			string(result_hash_text),
			string(result_hash_text),
		},
		{
			"source_independent_extrusion_replay",
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
			name = "plan-paths",
			schema_version =
				features.SCHEMA_VERSION_EXTRUSION_HASH,
			revision = EXTRUSION_MANIFEST_STAGE_REVISION,
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
	expectations, preflight_error := extrusion_manifest_preflight(
		manifest,
		"extrusion.bin",
		bytes,
	)
	testing.expect_value(
		t,
		preflight_error,
		Extrusion_Manifest_Error.None,
	)
	testing.expect_value(
		t,
		extrusion_manifest_replay_verify(expectations, decoded),
		Extrusion_Manifest_Error.None,
	)
	summary[0].value = 2
	_, summary_error := extrusion_manifest_preflight(
		manifest,
		"extrusion.bin",
		bytes,
	)
	testing.expect_value(
		t,
		summary_error,
		Extrusion_Manifest_Error.Summary_Mismatch,
	)
	summary[0].value = 1
	invariants[0].observed = GOLDEN_HASH
	_, invariant_error := extrusion_manifest_preflight(
		manifest,
		"extrusion.bin",
		bytes,
	)
	testing.expect_value(
		t,
		invariant_error,
		Extrusion_Manifest_Error.Invariant_Mismatch,
	)
	invariants[0].observed = string(result_hash_text)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[160] = corrupt[160] ~ 1
	_, artifact_error := extrusion_manifest_preflight(
		manifest,
		"extrusion.bin",
		corrupt,
	)
	testing.expect_value(
		t,
		artifact_error,
		Extrusion_Manifest_Error.Artifact_Hash_Mismatch,
	)
	expectations.layer_count = 2
	testing.expect_value(
		t,
		extrusion_manifest_replay_verify(expectations, decoded),
		Extrusion_Manifest_Error.Result_Mismatch,
	)
}
