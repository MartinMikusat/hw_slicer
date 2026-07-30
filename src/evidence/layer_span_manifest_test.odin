package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:testing"

import contracts "../contracts"
import slicing "../slicing"

@(test)
layer_span_manifest_binds_artifact_summary_and_result_test :: proc(
	t: ^testing.T,
) {
	result := layer_span_artifact_test_result()
	defer slicing.layer_span_index_destroy(&result)
	bytes, encode_error := layer_span_artifact_encode(
		LAYER_SPAN_ARTIFACT_TEST_SCHEDULE_HASH,
		result,
	)
	defer delete(bytes)
	testing.expect_value(
		t,
		encode_error,
		Layer_Span_Artifact_Error.None,
	)
	capture, capture_error := layer_span_capture_describe(
		"layer-spans.bin",
		{
			level = .Primitives,
			item_limit = 16,
			byte_limit = u64(len(bytes)),
		},
		{},
		bytes,
	)
	defer layer_span_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Layer_Span_Capture_Error.None,
	)
	decoded, decode_error := layer_span_artifact_decode(bytes)
	defer layer_span_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		Layer_Span_Artifact_Error.None,
	)
	result_hash_text := hex.encode(decoded.result_hash[:])
	defer delete(result_hash_text)
	provider, provider_ok := contracts.provider_descriptor_make(
		"cpu-layer-span-index",
		{0, 1, 0},
		.Build_Acceleration,
	)
	testing.expect(t, provider_ok)
	summary := [6]Evidence_Counter{
		{"span_triangles", 5},
		{"span_layers", 4},
		{"triangle_layer_pairs", 7},
		{"crossing_triangles", 2},
		{"planar_triangles", 2},
		{"inactive_triangles", 1},
	}
	invariants := [2]Evidence_Invariant{
		{
			"canonical_layer_span_result_hash",
			true,
			string(result_hash_text),
			string(result_hash_text),
		},
		{
			"source_independent_layer_span_replay",
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
			name = "build-acceleration",
			schema_version =
				slicing.SCHEMA_VERSION_LAYER_SPAN_INDEX_HASH,
			revision = LAYER_SPAN_MANIFEST_STAGE_REVISION,
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
	expectations, preflight_error := layer_span_manifest_preflight(
		manifest,
		"layer-spans.bin",
		bytes,
	)
	testing.expect_value(
		t,
		preflight_error,
		Layer_Span_Manifest_Error.None,
	)
	testing.expect_value(
		t,
		layer_span_manifest_replay_verify(expectations, decoded),
		Layer_Span_Manifest_Error.None,
	)
	summary[2].value = 8
	_, summary_error := layer_span_manifest_preflight(
		manifest,
		"layer-spans.bin",
		bytes,
	)
	testing.expect_value(
		t,
		summary_error,
		Layer_Span_Manifest_Error.Summary_Mismatch,
	)
	summary[2].value = 7
	invariants[0].observed = GOLDEN_HASH
	_, invariant_error := layer_span_manifest_preflight(
		manifest,
		"layer-spans.bin",
		bytes,
	)
	testing.expect_value(
		t,
		invariant_error,
		Layer_Span_Manifest_Error.Invariant_Mismatch,
	)
	invariants[0].observed = string(result_hash_text)
	corrupt := make([]u8, len(bytes), context.temp_allocator)
	copy(corrupt, bytes)
	corrupt[72] = corrupt[72] ~ 1
	_, artifact_error := layer_span_manifest_preflight(
		manifest,
		"layer-spans.bin",
		corrupt,
	)
	testing.expect_value(
		t,
		artifact_error,
		Layer_Span_Manifest_Error.Artifact_Hash_Mismatch,
	)
	expectations.layer_count = 5
	testing.expect_value(
		t,
		layer_span_manifest_replay_verify(expectations, decoded),
		Layer_Span_Manifest_Error.Result_Mismatch,
	)
}
