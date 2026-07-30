package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:testing"

import contracts "../contracts"
import slicing "../slicing"

@(test)
layer_schedule_manifest_binds_artifact_summary_and_result_test :: proc(
	t: ^testing.T,
) {
	bytes := layer_schedule_capture_test_artifact(t)
	defer delete(bytes)
	capture, capture_error := layer_schedule_capture_describe(
		"layer-schedule.bin",
		{
			level = .Primitives,
			item_limit = 1,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer layer_schedule_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Layer_Schedule_Capture_Error.None,
	)
	decoded, decode_error := layer_schedule_artifact_decode(bytes)
	defer layer_schedule_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		Layer_Schedule_Artifact_Error.None,
	)
	result_hash_text := hex.encode(decoded.result_hash[:])
	defer delete(result_hash_text)
	provider, provider_ok := contracts.provider_descriptor_make(
		"cpu-fixed-layer-schedule",
		{0, 1, 0},
		.Schedule_Layers,
	)
	testing.expect(t, provider_ok)
	summary := [1]Evidence_Counter{{"scheduled_layers", 1}}
	invariants := [2]Evidence_Invariant{
		{
			"canonical_layer_schedule_result_hash",
			true,
			string(result_hash_text),
			string(result_hash_text),
		},
		{
			"source_independent_layer_schedule_replay",
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
			name = "schedule-layers",
			schema_version =
				slicing.SCHEMA_VERSION_FIXED_LAYER_SCHEDULE_HASH,
			revision = LAYER_SCHEDULE_MANIFEST_STAGE_REVISION,
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
		layer_schedule_manifest_preflight(
			manifest,
			"layer-schedule.bin",
			bytes,
		)
	testing.expect_value(
		t,
		preflight_error,
		Layer_Schedule_Manifest_Error.None,
	)
	testing.expect_value(
		t,
		layer_schedule_manifest_replay_verify(
			expectations,
			decoded,
		),
		Layer_Schedule_Manifest_Error.None,
	)
	summary[0].value = 2
	_, summary_error := layer_schedule_manifest_preflight(
		manifest,
		"layer-schedule.bin",
		bytes,
	)
	testing.expect_value(
		t,
		summary_error,
		Layer_Schedule_Manifest_Error.Summary_Mismatch,
	)
	summary[0].value = 1
	invariants[0].observed = GOLDEN_HASH
	_, invariant_error := layer_schedule_manifest_preflight(
		manifest,
		"layer-schedule.bin",
		bytes,
	)
	testing.expect_value(
		t,
		invariant_error,
		Layer_Schedule_Manifest_Error.Invariant_Mismatch,
	)
	invariants[0].observed = string(result_hash_text)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[56] = corrupt[56] ~ 1
	_, artifact_error := layer_schedule_manifest_preflight(
		manifest,
		"layer-schedule.bin",
		corrupt,
	)
	testing.expect_value(
		t,
		artifact_error,
		Layer_Schedule_Manifest_Error.Artifact_Hash_Mismatch,
	)
	expectations.layer_count = 2
	testing.expect_value(
		t,
		layer_schedule_manifest_replay_verify(
			expectations,
			decoded,
		),
		Layer_Schedule_Manifest_Error.Result_Mismatch,
	)
}
