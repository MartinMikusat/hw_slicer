package evidence

import "core:encoding/hex"
import "core:testing"

import contracts "../contracts"
import features "../features"

@(test)
path_plan_manifest_binds_artifact_summary_hash_and_bounds_test :: proc(
	t: ^testing.T,
) {
	perimeter_hash, infill_hash, result := path_plan_artifact_test_fixture()
	defer features.path_plan_result_destroy(&result)
	result_hash, result_hash_ok := features.path_plan_result_hash(
		perimeter_hash,
		infill_hash,
		result,
	)
	testing.expect(t, result_hash_ok)
	result_hash_text := hex.encode(result_hash[:])
	defer delete(result_hash_text)
	capture, capture_error := path_plan_capture_encode(
		"path-plan.bin",
		{
			level = .Primitives,
			item_limit = 3,
			byte_limit = 336,
		},
		{},
		perimeter_hash,
		infill_hash,
		result,
	)
	defer path_plan_capture_destroy(&capture)
	testing.expect_value(t, capture_error, Path_Plan_Capture_Error.None)

	summary := [5]Evidence_Counter{
		{"layers", 1},
		{"paths", 1},
		{"moves", 1},
		{"travel_moves", 0},
		{"extrude_moves", 1},
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
		request_hash =
			"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		stage = {
			name = "plan-paths",
			schema_version = features.SCHEMA_VERSION_PATH_PLAN_HASH,
			revision = PATH_PLAN_MANIFEST_STAGE_REVISION,
		},
		provider = {
			id = "8d284a7409f377bb",
			name = "cpu-canonical-nearest",
			version = "0.1.0",
		},
		source_root_id = "8877665544332211",
		source_bounds = {units = "millimetre"},
		planar_bounds = {
			valid = true,
			minimum = {0, -25},
			maximum = {100, 0},
			units = "micrometre",
		},
		summary = summary[:],
		invariants = invariants[:],
		primitives = primitives[:],
	}
	expectations, preflight_error := path_plan_manifest_preflight(
		manifest,
		"path-plan.bin",
		capture.bytes,
	)
	testing.expect_value(t, preflight_error, Path_Plan_Manifest_Error.None)
	decoded, decode_error := path_plan_artifact_decode(capture.bytes)
	defer path_plan_artifact_destroy(&decoded)
	testing.expect_value(t, decode_error, Path_Plan_Artifact_Error.None)
	testing.expect_value(
		t,
		path_plan_manifest_replay_verify(expectations, decoded),
		Path_Plan_Manifest_Error.None,
	)

	summary[1].value = 2
	_, summary_error := path_plan_manifest_preflight(
		manifest,
		"path-plan.bin",
		capture.bytes,
	)
	testing.expect_value(
		t,
		summary_error,
		Path_Plan_Manifest_Error.Summary_Mismatch,
	)
	summary[1].value = 1

	invariants[0].observed =
		"1123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	_, invariant_error := path_plan_manifest_preflight(
		manifest,
		"path-plan.bin",
		capture.bytes,
	)
	testing.expect_value(
		t,
		invariant_error,
		Path_Plan_Manifest_Error.Invariant_Mismatch,
	)
	invariants[0].observed = string(result_hash_text)

	corrupt := make([]u8, len(capture.bytes), context.temp_allocator)
	copy(corrupt, capture.bytes)
	corrupt[200] = corrupt[200] ~ 1
	_, artifact_error := path_plan_manifest_preflight(
		manifest,
		"path-plan.bin",
		corrupt,
	)
	testing.expect_value(
		t,
		artifact_error,
		Path_Plan_Manifest_Error.Artifact_Hash_Mismatch,
	)

	expectations.bounds_maximum[0] += 1
	testing.expect_value(
		t,
		path_plan_manifest_replay_verify(expectations, decoded),
		Path_Plan_Manifest_Error.Bounds_Mismatch,
	)
}
