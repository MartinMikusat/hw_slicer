package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:testing"

import contracts "../contracts"
import features "../features"

@(test)
skin_manifest_binds_artifact_summary_and_result_test :: proc(t: ^testing.T) {
	fixture := skin_capture_test_fixture(t)
	defer skin_capture_test_fixture_destroy(&fixture)
	capture, capture_error := skin_capture_describe(
		"skins.bin",
		{
			level = .Primitives,
			item_limit = 7,
			byte_limit = u64(len(fixture.bytes)),
		},
		{},
		fixture.bytes,
		fixture.surface_hash,
		fixture.schedule_hash,
		fixture.regions,
		fixture.surfaces,
	)
	defer skin_capture_destroy(&capture)
	testing.expect_value(t, capture_error, Skin_Capture_Error.None)
	decoded, decode_error := features.skin_artifact_decode(
		fixture.bytes,
		fixture.surface_hash,
		fixture.schedule_hash,
		fixture.regions,
		fixture.surfaces,
	)
	defer features.skin_artifact_destroy(&decoded)
	testing.expect_value(
		t,
		decode_error,
		features.Skin_Artifact_Error.None,
	)
	result_hash_text := hex.encode(decoded.result_hash[:])
	defer delete(result_hash_text)
	provider, provider_ok := contracts.provider_descriptor_make(
		"cpu-skin-propagation",
		{0, 1, 0},
		.Generate_Features,
	)
	testing.expect(t, provider_ok)
	summary := [8]Evidence_Counter{
		{"skin_layers", 1},
		{"skin_masks", 1},
		{"skin_paths", 1},
		{"skin_points", 3},
		{"skin_source_references", 1},
		{"skin_bottom_masks", 1},
		{"skin_top_masks", 0},
		{"skin_top_bottom_masks", 0},
	}
	invariants := [2]Evidence_Invariant{
		{
			"canonical_skin_result_hash",
			true,
			string(result_hash_text),
			string(result_hash_text),
		},
		{
			"source_independent_skin_replay",
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
			schema_version = features.SCHEMA_VERSION_SKIN_HASH,
			revision = SKIN_MANIFEST_STAGE_REVISION,
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
	expectations, preflight_error := skin_manifest_preflight(
		manifest,
		"skins.bin",
		fixture.bytes,
	)
	testing.expect_value(t, preflight_error, Skin_Manifest_Error.None)
	testing.expect_value(
		t,
		skin_manifest_replay_verify(expectations, decoded),
		Skin_Manifest_Error.None,
	)
	summary[0].value = 2
	_, summary_error := skin_manifest_preflight(
		manifest,
		"skins.bin",
		fixture.bytes,
	)
	testing.expect_value(
		t,
		summary_error,
		Skin_Manifest_Error.Summary_Mismatch,
	)
	summary[0].value = 1
	invariants[0].observed = GOLDEN_HASH
	_, invariant_error := skin_manifest_preflight(
		manifest,
		"skins.bin",
		fixture.bytes,
	)
	testing.expect_value(
		t,
		invariant_error,
		Skin_Manifest_Error.Invariant_Mismatch,
	)
	invariants[0].observed = string(result_hash_text)
	corrupt := make([]u8, len(fixture.bytes), context.temp_allocator)
	copy(corrupt, fixture.bytes)
	corrupt[112] = corrupt[112] ~ 1
	_, artifact_error := skin_manifest_preflight(
		manifest,
		"skins.bin",
		corrupt,
	)
	testing.expect_value(
		t,
		artifact_error,
		Skin_Manifest_Error.Artifact_Hash_Mismatch,
	)
	expectations.layer_count = 2
	testing.expect_value(
		t,
		skin_manifest_replay_verify(expectations, decoded),
		Skin_Manifest_Error.Result_Mismatch,
	)
}
