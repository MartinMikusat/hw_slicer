package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:testing"

import contracts "../contracts"
import gcode "../gcode"

@(test)
marlin_manifest_binds_stage_descriptor_summary_and_result_test :: proc(
	t: ^testing.T,
) {
	bytes := marlin_capture_test_artifact(t)
	defer delete(bytes)
	capture, capture_error := marlin_capture_describe(
		"marlin.bin",
		{
			level = .Primitives,
			item_limit = 1,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer marlin_capture_destroy(&capture)
	testing.expect_value(t, capture_error, Marlin_Capture_Error.None)
	decoded, decode_error := gcode.marlin_artifact_decode(bytes)
	defer gcode.marlin_artifact_destroy(&decoded)
	testing.expect_value(t, decode_error, gcode.Marlin_Artifact_Error.None)
	result_hash_text := hex.encode(decoded.result_hash[:])
	defer delete(result_hash_text)
	provider, provider_ok := contracts.provider_descriptor_make(
		"cpu-marlin-conservative",
		{0, 1, 0},
		.Emit_GCode,
	)
	testing.expect(t, provider_ok)
	summary := [6]Evidence_Counter{
		{"commands", 1},
		{"gcode_bytes", 4},
		{"layers", 1},
		{"motion_operations", 1},
		{"dwell_ms", 0},
		{"shutdown_retraction_nm", 0},
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
	manifest := Evidence_Manifest{
		schema_version = contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		request_hash = GOLDEN_HASH,
		stage = {
			name = "emit-gcode",
			schema_version = gcode.MARLIN_EMITTER_SCHEMA_VERSION,
			revision = MARLIN_MANIFEST_STAGE_REVISION,
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
	expectations, preflight_error := marlin_manifest_preflight(
		manifest,
		"marlin.bin",
		bytes,
	)
	testing.expect_value(
		t,
		preflight_error,
		Marlin_Manifest_Error.None,
	)
	testing.expect_value(
		t,
		marlin_manifest_replay_verify(expectations, decoded),
		Marlin_Manifest_Error.None,
	)

	summary[0].value = 2
	_, summary_error := marlin_manifest_preflight(
		manifest,
		"marlin.bin",
		bytes,
	)
	testing.expect_value(
		t,
		summary_error,
		Marlin_Manifest_Error.Summary_Mismatch,
	)
	summary[0].value = 1
	invariants[0].observed = GOLDEN_HASH
	_, invariant_error := marlin_manifest_preflight(
		manifest,
		"marlin.bin",
		bytes,
	)
	testing.expect_value(
		t,
		invariant_error,
		Marlin_Manifest_Error.Invariant_Mismatch,
	)
	invariants[0].observed = string(result_hash_text)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[len(corrupt)-2] = '3'
	_, artifact_error := marlin_manifest_preflight(
		manifest,
		"marlin.bin",
		corrupt,
	)
	testing.expect_value(
		t,
		artifact_error,
		Marlin_Manifest_Error.Artifact_Hash_Mismatch,
	)
	expectations.command_count = 2
	testing.expect_value(
		t,
		marlin_manifest_replay_verify(expectations, decoded),
		Marlin_Manifest_Error.Result_Mismatch,
	)
}
