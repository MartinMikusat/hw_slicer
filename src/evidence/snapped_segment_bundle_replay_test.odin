package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:os/os2"
import "core:testing"

import contracts "../contracts"
import formats "../formats"
import slicing "../slicing"

@(test)
snapped_segment_bundle_replays_package_and_directory_test :: proc(
	t: ^testing.T,
) {
	result := snapped_segment_artifact_test_result()
	defer slicing.snapped_segments_destroy(&result)
	artifact_bytes, encode_error := snapped_segment_artifact_encode(
		SNAPPED_SEGMENT_ARTIFACT_TEST_PARENT_HASH,
		result,
	)
	defer delete(artifact_bytes)
	testing.expect_value(
		t,
		encode_error,
		Snapped_Segment_Artifact_Error.None,
	)
	artifact_path :=
		"stages/06-intersect/primitives/snapped-segments.bin"
	capture, capture_error := snapped_segment_capture_describe(
		artifact_path,
		{
			level = .Primitives,
			item_limit = 4,
			byte_limit = u64(len(artifact_bytes)),
		},
		{},
		artifact_bytes,
	)
	defer snapped_segment_capture_destroy(&capture)
	testing.expect_value(
		t,
		capture_error,
		Snapped_Segment_Capture_Error.None,
	)
	decoded, decode_error :=
		snapped_segment_artifact_decode(artifact_bytes)
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
	stage_manifest := Evidence_Manifest{
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
			"stages/06-intersect/manifest.json",
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
			ordinal = u32(contracts.Stage_Kind.Intersect),
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
	snapped_segment_bundle_expect_replay(t, package_replay)

	directory_root := directory_test_root(t)
	defer {
		os2.remove_all(directory_root)
		delete(directory_root)
	}
	destination := directory_test_join(
		t,
		{directory_root, "snapped-segment-evidence"},
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
	snapped_segment_bundle_expect_replay(t, directory_replay)
}

@(test)
snapped_segment_bundle_dependency_chain_uses_retained_graph_test :: proc(
	t: ^testing.T,
) {
	replay := Evidence_Bundle_Replay{
		intersections_loaded = true,
		snapped_loaded = true,
		topology_loaded = true,
	}
	replay.intersections.result.layers =
		[]slicing.Intersection_Layer{{}, {}}
	replay.snapped.result_hash =
		SNAPPED_SEGMENT_ARTIFACT_TEST_PARENT_HASH
	replay.snapped.result.layers =
		[]slicing.Snapped_Layer{{}, {}}
	replay.topology.snapped_hash =
		SNAPPED_SEGMENT_ARTIFACT_TEST_PARENT_HASH
	replay.topology.result.layers =
		[]slicing.Topology_Layer{{}, {}}
	testing.expect(t, evidence_bundle_replay_dependencies_valid(replay))
	replay.topology.snapped_hash[0] += 1
	testing.expect(t, !evidence_bundle_replay_dependencies_valid(replay))
	replay.topology.snapped_hash[0] -= 1
	replay.topology.result.layers =
		replay.topology.result.layers[:1]
	testing.expect(t, !evidence_bundle_replay_dependencies_valid(replay))
	replay.topology.result.layers =
		[]slicing.Topology_Layer{{}, {}}
	replay.intersections.result.layers =
		replay.intersections.result.layers[:1]
	testing.expect(t, !evidence_bundle_replay_dependencies_valid(replay))
}

snapped_segment_bundle_expect_replay :: proc(
	t: ^testing.T,
	replay: Evidence_Bundle_Replay,
) {
	testing.expect(t, replay.snapped_loaded)
	testing.expect(t, !replay.layer_schedule_loaded)
	testing.expect(t, !replay.layer_spans_loaded)
	testing.expect(t, !replay.intersections_loaded)
	testing.expect(t, !replay.topology_loaded)
	testing.expect(t, !replay.regions_loaded)
	testing.expect(t, !replay.path_plan_loaded)
	testing.expect(t, !replay.surfaces_loaded)
	testing.expect(t, !replay.perimeters_loaded)
	testing.expect(t, !replay.infill_loaded)
	testing.expect(t, !replay.unified_sources_loaded)
	testing.expect(t, !replay.unified_plan_loaded)
	testing.expect(t, !replay.extrusion_loaded)
	testing.expect(t, !replay.motion_plan_loaded)
	testing.expect(t, !replay.marlin_loaded)
	testing.expect_value(t, len(replay.stage_manifests), 1)
	testing.expect_value(t, len(replay.snapped.result.layers), 2)
	testing.expect_value(
		t,
		len(replay.snapped.result.segments.segment_ids),
		2,
	)
	testing.expect_value(
		t,
		replay.snapped.result.collapsed_count,
		u64(1),
	)
}
