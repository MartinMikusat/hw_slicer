package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:os/os2"
import "core:testing"

import contracts "../contracts"
import features "../features"
import formats "../formats"

@(test)
motion_plan_bundle_replays_with_path_plan_without_source_test :: proc(
	t: ^testing.T,
) {
	perimeter_hash, infill_hash, path_result :=
		path_plan_artifact_test_fixture()
	defer features.path_plan_result_destroy(&path_result)
	path_capture, path_capture_error := path_plan_capture_encode(
		"stages/10-plan-paths/primitives/path-plan.bin",
		{
			level = .Primitives,
			item_limit = 3,
			byte_limit = 1024,
		},
		{},
		perimeter_hash,
		infill_hash,
		path_result,
	)
	defer path_plan_capture_destroy(&path_capture)
	testing.expect_value(
		t,
		path_capture_error,
		Path_Plan_Capture_Error.None,
	)
	path_artifact, path_decode_error :=
		path_plan_artifact_decode(path_capture.bytes)
	defer path_plan_artifact_destroy(&path_artifact)
	testing.expect_value(
		t,
		path_decode_error,
		Path_Plan_Artifact_Error.None,
	)
	path_hash_text := hex.encode(path_artifact.result_hash[:])
	defer delete(path_hash_text)

	motion_bytes := motion_plan_capture_test_artifact(t)
	defer delete(motion_bytes)
	motion_capture, motion_capture_error := motion_plan_capture_describe(
		"stages/10-plan-paths/primitives/motion.bin",
		{
			level = .Primitives,
			item_limit = 1,
			byte_limit = u64(len(motion_bytes)),
		},
		{},
		motion_bytes,
	)
	defer motion_plan_capture_destroy(&motion_capture)
	testing.expect_value(
		t,
		motion_capture_error,
		Motion_Plan_Capture_Error.None,
	)
	motion_artifact, motion_decode_error :=
		features.motion_plan_artifact_decode(motion_bytes)
	defer features.motion_plan_artifact_destroy(&motion_artifact)
	testing.expect_value(
		t,
		motion_decode_error,
		features.Motion_Plan_Artifact_Error.None,
	)
	motion_hash_text := hex.encode(motion_artifact.result_hash[:])
	defer delete(motion_hash_text)

	provider, provider_ok := contracts.provider_descriptor_make(
		"cpu-plan-paths",
		{0, 1, 0},
		.Plan_Paths,
	)
	testing.expect(t, provider_ok)
	summary := [14]Evidence_Counter{
		{"layers", u64(len(path_artifact.result.layers))},
		{"paths", u64(len(path_artifact.result.paths))},
		{"moves", u64(len(path_artifact.result.moves))},
		{"travel_moves", path_artifact.result.travel_move_count},
		{"extrude_moves", path_artifact.result.extrude_move_count},
		{"motion_layers", u64(len(motion_artifact.result.layers))},
		{"motion_operations", u64(len(motion_artifact.result.operations))},
		{"retractions", motion_artifact.result.retraction_count},
		{"motion_travels", motion_artifact.result.travel_count},
		{"motion_extrusions", motion_artifact.result.extrusion_count},
		{"motion_dwells", motion_artifact.result.dwell_count},
		{
			"motion_duration_us",
			motion_artifact.result.total_motion_duration_us,
		},
		{
			"dwell_duration_us",
			motion_artifact.result.total_dwell_duration_us,
		},
		{
			"planned_duration_us",
			motion_artifact.result.total_planned_duration_us,
		},
	}
	invariants := [4]Evidence_Invariant{
		{
			"canonical_result_hash",
			true,
			string(path_hash_text),
			string(path_hash_text),
		},
		{
			"source_independent_replay",
			true,
			"passed",
			"passed",
		},
		{
			"canonical_motion_result_hash",
			true,
			string(motion_hash_text),
			string(motion_hash_text),
		},
		{
			"source_independent_motion_replay",
			true,
			"passed",
			"passed",
		},
	}
	primitives := [2]Evidence_Artifact{
		motion_capture.artifact,
		path_capture.artifact,
	}
	stage_manifest := Evidence_Manifest{
		schema_version = contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		request_hash = GOLDEN_HASH,
		stage = {
			name = "plan-paths",
			schema_version = features.SCHEMA_VERSION_PATH_PLAN_HASH,
			revision = PATH_PLAN_MANIFEST_STAGE_REVISION,
		},
		provider = {
			id = fmt.tprintf("%016x", u64(provider.id)),
			name = provider.name,
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
	stage_bytes, stage_error := evidence_manifest_encode(stage_manifest)
	defer delete(stage_bytes)
	testing.expect_value(t, stage_error, Evidence_Error.None)
	stage_descriptor, stage_descriptor_error :=
		evidence_artifact_describe(
			"stages/10-plan-paths/manifest.json",
			"json",
			contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
			1,
			stage_bytes,
		)
	defer evidence_artifact_destroy(&stage_descriptor)
	testing.expect_value(
		t,
		stage_descriptor_error,
		Evidence_Artifact_Describe_Error.None,
	)

	bundle_summary_record := Evidence_Bundle_Summary{
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = GOLDEN_HASH,
		source_root_id = stage_manifest.source_root_id,
		stage_count = 1,
		file_count = 2,
	}
	bundle_summary_bytes, bundle_summary_error :=
		evidence_bundle_summary_encode(bundle_summary_record)
	defer delete(bundle_summary_bytes)
	testing.expect_value(
		t,
		bundle_summary_error,
		Evidence_Bundle_Error.None,
	)
	bundle_summary, bundle_summary_descriptor_error :=
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
		bundle_summary_descriptor_error,
		Evidence_Artifact_Describe_Error.None,
	)
	stages := [1]Evidence_Bundle_Stage{
		{
			ordinal = u32(contracts.Stage_Kind.Plan_Paths),
			stage = stage_manifest.stage,
			provider = stage_manifest.provider,
			manifest = stage_descriptor,
		},
	}
	files := [2]Evidence_Artifact{
		motion_capture.artifact,
		path_capture.artifact,
	}
	root := Evidence_Bundle_Manifest{
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = GOLDEN_HASH,
		source_root_id = stage_manifest.source_root_id,
		summary = bundle_summary,
		stages = stages[:],
		files = files[:],
	}
	contents := [4]Evidence_Bundle_Content{
		{bundle_summary.path, bundle_summary_bytes},
		{stage_descriptor.path, stage_bytes},
		{motion_capture.artifact.path, motion_bytes},
		{path_capture.artifact.path, path_capture.bytes},
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
	motion_plan_bundle_expect_replay(t, package_replay)

	directory_root := directory_test_root(t)
	defer {
		os2.remove_all(directory_root)
		delete(directory_root)
	}
	destination := directory_test_join(
		t,
		{directory_root, "motion-plan-evidence"},
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
	motion_plan_bundle_expect_replay(t, directory_replay)
}

motion_plan_bundle_expect_replay :: proc(
	t: ^testing.T,
	replay: Evidence_Bundle_Replay,
) {
	testing.expect(t, replay.path_plan_loaded)
	testing.expect(t, replay.motion_plan_loaded)
	testing.expect(t, !replay.topology_loaded)
	testing.expect(t, !replay.regions_loaded)
	testing.expect(t, !replay.marlin_loaded)
	testing.expect_value(t, len(replay.stage_manifests), 1)
	testing.expect_value(t, len(replay.path_plan.result.layers), 1)
	testing.expect_value(t, len(replay.path_plan.result.paths), 1)
	testing.expect_value(t, len(replay.path_plan.result.moves), 1)
	testing.expect_value(t, len(replay.motion_plan.result.layers), 1)
	testing.expect_value(t, len(replay.motion_plan.result.operations), 0)
}
