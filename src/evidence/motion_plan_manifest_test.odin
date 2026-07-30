package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:testing"

import contracts "../contracts"
import features "../features"

@(test)
motion_plan_manifest_binds_artifact_summary_and_result_test :: proc(
	t: ^testing.T,
) {
	bytes := motion_plan_capture_test_artifact(t)
	defer delete(bytes)
	capture, capture_error := motion_plan_capture_describe(
		"motion.bin",
		{
			level = .Primitives,
			item_limit = 1,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer motion_plan_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Motion_Plan_Capture_Error.None,
	)
	decoded, decode_error := features.motion_plan_artifact_decode(bytes)
	defer features.motion_plan_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		features.Motion_Plan_Artifact_Error.None,
	)
	result_hash_text := hex.encode(decoded.result_hash[:])
	defer delete(result_hash_text)
	provider, provider_ok := contracts.provider_descriptor_make(
		"cpu-motion-plan",
		{0, 1, 0},
		.Plan_Paths,
	)
	testing.expect(t, provider_ok)
	summary := [9]Evidence_Counter{
		{"motion_layers", 1},
		{"motion_operations", 0},
		{"retractions", 0},
		{"motion_travels", 0},
		{"motion_extrusions", 0},
		{"motion_dwells", 0},
		{"motion_duration_us", 0},
		{"dwell_duration_us", 0},
		{"planned_duration_us", 0},
	}
	invariants := [2]Evidence_Invariant{
		{
			"canonical_motion_result_hash",
			true,
			string(result_hash_text),
			string(result_hash_text),
		},
		{
			"source_independent_motion_replay",
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
				features.SCHEMA_VERSION_MOTION_PLAN_HASH,
			revision = MOTION_PLAN_MANIFEST_STAGE_REVISION,
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
	expectations, preflight_error := motion_plan_manifest_preflight(
		manifest,
		"motion.bin",
		bytes,
	)
	testing.expect_value(
		t,
		preflight_error,
		Motion_Plan_Manifest_Error.None,
	)
	testing.expect_value(
		t,
		motion_plan_manifest_replay_verify(expectations, decoded),
		Motion_Plan_Manifest_Error.None,
	)
	summary[0].value = 2
	_, summary_error := motion_plan_manifest_preflight(
		manifest,
		"motion.bin",
		bytes,
	)
	testing.expect_value(
		t,
		summary_error,
		Motion_Plan_Manifest_Error.Summary_Mismatch,
	)
	summary[0].value = 1
	invariants[0].observed = GOLDEN_HASH
	_, invariant_error := motion_plan_manifest_preflight(
		manifest,
		"motion.bin",
		bytes,
	)
	testing.expect_value(
		t,
		invariant_error,
		Motion_Plan_Manifest_Error.Invariant_Mismatch,
	)
	invariants[0].observed = string(result_hash_text)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[160] = corrupt[160] ~ 1
	_, artifact_error := motion_plan_manifest_preflight(
		manifest,
		"motion.bin",
		corrupt,
	)
	testing.expect_value(
		t,
		artifact_error,
		Motion_Plan_Manifest_Error.Artifact_Hash_Mismatch,
	)
	expectations.layer_count = 2
	testing.expect_value(
		t,
		motion_plan_manifest_replay_verify(expectations, decoded),
		Motion_Plan_Manifest_Error.Result_Mismatch,
	)
}
