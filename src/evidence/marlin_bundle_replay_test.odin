package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:os/os2"
import "core:testing"

import contracts "../contracts"
import formats "../formats"
import gcode "../gcode"

@(test)
marlin_bundle_replays_package_and_directory_without_source_test :: proc(
	t: ^testing.T,
) {
	artifact_bytes := marlin_capture_test_artifact(t)
	defer delete(artifact_bytes)
	artifact_path := "stages/11-emit-gcode/primitives/marlin.bin"
	capture, capture_error := marlin_capture_describe(
		artifact_path,
		{
			level = .Primitives,
			item_limit = 1,
			byte_limit = u64(len(artifact_bytes)),
		},
		{},
		artifact_bytes,
	)
	defer marlin_capture_destroy(&capture)
	testing.expect_value(t, capture_error, Marlin_Capture_Error.None)
	decoded, decode_error := gcode.marlin_artifact_decode(artifact_bytes)
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
	stage_manifest := Evidence_Manifest{
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
	stage_manifest_bytes, stage_manifest_error :=
		evidence_manifest_encode(stage_manifest)
	defer delete(stage_manifest_bytes)
	testing.expect_value(
		t,
		stage_manifest_error,
		Evidence_Error.None,
	)
	stage_manifest_artifact, stage_describe_error :=
		evidence_artifact_describe(
			"stages/11-emit-gcode/manifest.json",
			"json",
			contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
			1,
			stage_manifest_bytes,
		)
	defer evidence_artifact_destroy(&stage_manifest_artifact)
	testing.expect_value(
		t,
		stage_describe_error,
		Evidence_Artifact_Describe_Error.None,
	)
	bundle_summary_record := Evidence_Bundle_Summary{
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = GOLDEN_HASH,
		source_root_id = "8877665544332211",
		stage_count = 1,
		file_count = 1,
	}
	bundle_summary_bytes, bundle_summary_error :=
		evidence_bundle_summary_encode(bundle_summary_record)
	defer delete(bundle_summary_bytes)
	testing.expect_value(
		t,
		bundle_summary_error,
		Evidence_Bundle_Error.None,
	)
	bundle_summary, summary_describe_error :=
		evidence_artifact_describe(
			"summary.json",
			"json",
			EVIDENCE_BUNDLE_SCHEMA_VERSION,
			1,
			bundle_summary_bytes,
		)
	defer evidence_artifact_destroy(&bundle_summary)
	testing.expect_value(
		t,
		summary_describe_error,
		Evidence_Artifact_Describe_Error.None,
	)
	stages := [1]Evidence_Bundle_Stage{
		{
			ordinal = u32(contracts.Stage_Kind.Emit_GCode),
			stage = stage_manifest.stage,
			provider = stage_manifest.provider,
			manifest = stage_manifest_artifact,
		},
	}
	files := [1]Evidence_Artifact{capture.artifact}
	root := Evidence_Bundle_Manifest{
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = GOLDEN_HASH,
		source_root_id = "8877665544332211",
		summary = bundle_summary,
		stages = stages[:],
		files = files[:],
	}
	contents := [3]Evidence_Bundle_Content{
		{bundle_summary.path, bundle_summary_bytes},
		{stage_manifest_artifact.path, stage_manifest_bytes},
		{capture.artifact.path, artifact_bytes},
	}
	package_bytes, package_error :=
		evidence_bundle_package_encode(root, contents[:])
	defer delete(package_bytes)
	testing.expect_value(
		t,
		package_error,
		Evidence_Bundle_Package_Error.None,
	)
	package_replay, package_replay_error :=
		evidence_bundle_package_replay(package_bytes)
	defer evidence_bundle_replay_destroy(&package_replay)
	testing.expect_value(
		t,
		package_replay_error,
		Evidence_Bundle_Package_Error.None,
	)
	marlin_bundle_expect_replay(t, package_replay)

	directory_root := directory_test_root(t)
	defer {
		os2.remove_all(directory_root)
		delete(directory_root)
	}
	destination := directory_test_join(
		t,
		{directory_root, "marlin-evidence"},
	)
	defer delete(destination)
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(
			root,
			contents[:],
			destination,
		),
		Evidence_Bundle_Directory_Error.None,
	)
	directory_replay, directory_replay_error :=
		evidence_bundle_directory_replay(
			destination,
			formats.DEFAULT_BOUNDED_ZIP_LIMITS,
		)
	defer evidence_bundle_replay_destroy(&directory_replay)
	testing.expect_value(
		t,
		directory_replay_error,
		Evidence_Bundle_Directory_Error.None,
	)
	marlin_bundle_expect_replay(t, directory_replay)
}

marlin_bundle_expect_replay :: proc(
	t: ^testing.T,
	replay: Evidence_Bundle_Replay,
) {
	testing.expect(t, replay.marlin_loaded)
	testing.expect(t, !replay.topology_loaded)
	testing.expect(t, !replay.regions_loaded)
	testing.expect(t, !replay.path_plan_loaded)
	testing.expect_value(t, len(replay.stage_manifests), 1)
	testing.expect_value(t, len(replay.marlin.result.commands), 1)
	testing.expect_value(t, string(replay.marlin.result.bytes), "G21\n")
}
