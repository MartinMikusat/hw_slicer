package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:testing"

import contracts "../contracts"
import slicing "../slicing"

@(test)
snapped_segment_manifest_binds_artifact_summary_and_result_test :: proc(
	t: ^testing.T,
) {
	result := snapped_segment_artifact_test_result()
	defer slicing.snapped_segments_destroy(&result)
	bytes, encode_error := snapped_segment_artifact_encode(
		SNAPPED_SEGMENT_ARTIFACT_TEST_PARENT_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Snapped_Segment_Artifact_Error.None,
	)
	capture, capture_error := snapped_segment_capture_describe(
		"snapped-segments.bin",
		{
			level = .Primitives,
			item_limit = 4,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer snapped_segment_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Snapped_Segment_Capture_Error.None,
	)
	decoded, decode_error := snapped_segment_artifact_decode(bytes)
	defer snapped_segment_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		Snapped_Segment_Artifact_Error.None,
	)
	result_hash_text := hex.encode(decoded.result_hash[:])
	defer delete(result_hash_text)
	provider, provider_ok := contracts.provider_descriptor_make(
		"cpu-intersection-resolution",
		{0, 1, 0},
		.Intersect,
	)
	testing.expect(t, provider_ok)
	summary := [4]Evidence_Counter{
		{"snapped_layers", 2},
		{"snapped_segments", 2},
		{"collapsed_segments", 1},
		{"snap_grid_um", 1},
	}
	invariants := [2]Evidence_Invariant{
		{
			"canonical_snapped_segment_result_hash",
			true,
			string(result_hash_text),
			string(result_hash_text),
		},
		{
			"source_independent_snapped_segment_replay",
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
				slicing.SCHEMA_VERSION_SNAPPED_SEGMENT_HASH,
			revision = SNAPPED_SEGMENT_MANIFEST_STAGE_REVISION,
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
		snapped_segment_manifest_preflight(
			manifest,
			"snapped-segments.bin",
			bytes,
		)
	testing.expect_value(
		t,
		preflight_error,
		Snapped_Segment_Manifest_Error.None,
	)
	testing.expect_value(
		t,
		snapped_segment_manifest_replay_verify(
			expectations,
			decoded,
		),
		Snapped_Segment_Manifest_Error.None,
	)
	summary[1].value = 3
	_, summary_error := snapped_segment_manifest_preflight(
		manifest,
		"snapped-segments.bin",
		bytes,
	)
	testing.expect_value(
		t,
		summary_error,
		Snapped_Segment_Manifest_Error.Summary_Mismatch,
	)
	summary[1].value = 2
	invariants[0].observed = GOLDEN_HASH
	_, invariant_error := snapped_segment_manifest_preflight(
		manifest,
		"snapped-segments.bin",
		bytes,
	)
	testing.expect_value(
		t,
		invariant_error,
		Snapped_Segment_Manifest_Error.Invariant_Mismatch,
	)
	invariants[0].observed = string(result_hash_text)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[72] = corrupt[72] ~ 1
	_, artifact_error := snapped_segment_manifest_preflight(
		manifest,
		"snapped-segments.bin",
		corrupt,
	)
	testing.expect_value(
		t,
		artifact_error,
		Snapped_Segment_Manifest_Error.Artifact_Hash_Mismatch,
	)
	expectations.layer_count = 3
	testing.expect_value(
		t,
		snapped_segment_manifest_replay_verify(
			expectations,
			decoded,
		),
		Snapped_Segment_Manifest_Error.Result_Mismatch,
	)
}
