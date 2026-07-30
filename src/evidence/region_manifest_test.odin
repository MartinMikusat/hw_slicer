package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:testing"

import contracts "../contracts"
import slicing "../slicing"

@(test)
region_manifest_binds_artifact_summary_hash_and_bounds_test :: proc(
	t: ^testing.T,
) {
	topology_hash, topology, regions := region_artifact_test_fixture()
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	result_hash, result_hash_ok := slicing.region_result_hash(
		topology_hash,
		topology,
		regions,
	)
	testing.expect(t, result_hash_ok)
	result_hash_text := hex.encode(result_hash[:])
	defer delete(result_hash_text)
	capture, capture_error := region_capture_encode(
		"regions.bin",
		{
			level = .Primitives,
			item_limit = 9,
			byte_limit = 548,
		},
		{},
		topology_hash,
		topology,
		regions,
	)
	defer region_capture_destroy(&capture)
	testing.expect_value(t, capture_error, Region_Capture_Error.None)
	summary := [5]Evidence_Counter{
		{"layers", 1},
		{"contours", 3},
		{"regions", 2},
		{"region_contour_indices", 3},
		{"holes", 1},
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
	provider := slicing.cpu_region_provider_descriptor()
	manifest := Evidence_Manifest{
		schema_version = contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		request_hash =
			"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		stage = {
			name = "calculate-regions",
			schema_version = slicing.SCHEMA_VERSION_REGION_HASH,
			revision = REGION_MANIFEST_STAGE_REVISION,
		},
		provider = {
			id = fmt.tprintf("%016x", u64(provider.id)),
			name = slicing.CPU_REGION_PROVIDER_NAME,
			version = "0.1.0",
		},
		source_root_id = "8877665544332211",
		source_bounds = {units = "millimetre"},
		planar_bounds = {
			valid = true,
			minimum = {0, 0},
			maximum = {100, 100},
			units = "micrometre",
		},
		summary = summary[:],
		invariants = invariants[:],
		primitives = primitives[:],
	}
	expectations, preflight_error := region_manifest_preflight(
		manifest,
		"regions.bin",
		capture.bytes,
	)
	testing.expect_value(t, preflight_error, Region_Manifest_Error.None)
	decoded, decode_error := region_artifact_decode(
		capture.bytes,
		topology_hash,
		topology,
	)
	defer region_artifact_destroy(&decoded)
	testing.expect_value(t, decode_error, Region_Artifact_Error.None)
	testing.expect_value(
		t,
		region_manifest_replay_verify(expectations, decoded),
		Region_Manifest_Error.None,
	)
	summary[3].value = 2
	_, summary_error := region_manifest_preflight(
		manifest,
		"regions.bin",
		capture.bytes,
	)
	testing.expect_value(
		t,
		summary_error,
		Region_Manifest_Error.Summary_Mismatch,
	)
	summary[3].value = 3
	expectations.bounds_maximum[0] += 1
	testing.expect_value(
		t,
		region_manifest_replay_verify(expectations, decoded),
		Region_Manifest_Error.Bounds_Mismatch,
	)
}
