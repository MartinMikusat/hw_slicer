package evidence

import "core:encoding/hex"
import "core:fmt"
import "core:os/os2"
import "core:testing"

import contracts "../contracts"
import features "../features"
import formats "../formats"
import polygon "../polygon"
import slicing "../slicing"

@(test)
skin_bundle_replays_dependent_graph_from_package_and_directory_test :: proc(
	t: ^testing.T,
) {
	topology_hash, topology, regions := region_artifact_test_fixture()
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	schedule, schedule_error := slicing.fixed_layer_schedule_build({
		request_hash = Skin_Bundle_Schedule_Request_Hash,
		minimum_z = 0,
		maximum_z = 200,
		first_plane_z = 100,
		layer_step = 200,
		max_layer_count = 1,
	})
	defer slicing.fixed_layer_schedule_destroy(&schedule)
	testing.expect_value(t, schedule_error, slicing.Schedule_Error.None)
	schedule_bytes, schedule_encode_error :=
		layer_schedule_artifact_encode(schedule)
	defer delete(schedule_bytes)
	testing.expect_value(
		t,
		schedule_encode_error,
		Layer_Schedule_Artifact_Error.None,
	)
	schedule_capture, schedule_capture_error :=
		layer_schedule_capture_describe(
			"stages/04-schedule-layers/primitives/layer-schedule.bin",
			{
				level = .Primitives,
				item_limit = 1,
				byte_limit = u64(len(schedule_bytes)),
			},
			{},
			schedule_bytes,
		)
	defer layer_schedule_capture_destroy(&schedule_capture)
	testing.expect_value(
		t,
		schedule_capture_error,
		Layer_Schedule_Capture_Error.None,
	)
	schedule_artifact, schedule_decode_error :=
		layer_schedule_artifact_decode(schedule_bytes)
	defer layer_schedule_artifact_destroy(&schedule_artifact)
	testing.expect_value(
		t,
		schedule_decode_error,
		Layer_Schedule_Artifact_Error.None,
	)

	snapped_hash: contracts.Content_Hash
	for &byte, byte_index in snapped_hash {
		byte = u8(0x80+byte_index)
	}
	topology_capture, topology_capture_error := topology_capture_encode(
		"stages/07-reconstruct-topology/primitives/topology.bin",
		{
			level = .Primitives,
			item_limit = 40,
			byte_limit = 912,
		},
		{},
		snapped_hash,
		12,
		topology,
	)
	defer topology_capture_destroy(&topology_capture)
	testing.expect_value(
		t,
		topology_capture_error,
		Topology_Capture_Error.None,
	)
	region_capture, region_capture_error := region_capture_encode(
		"stages/08-calculate-regions/primitives/regions.bin",
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
	defer region_capture_destroy(&region_capture)
	testing.expect_value(
		t,
		region_capture_error,
		Region_Capture_Error.None,
	)
	region_hash, region_hash_ok := slicing.region_result_hash(
		topology_hash,
		topology,
		regions,
	)
	testing.expect(t, region_hash_ok)
	surfaces, surface_error := features.surfaces_classify(
		topology,
		regions,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			topology_policy = .Strict_Printable,
		},
	)
	defer features.surface_result_destroy(&surfaces)
	testing.expect_value(t, surface_error, features.Surface_Error.None)
	surface_bytes, surface_encode_error := features.surface_artifact_encode(
		region_hash,
		surfaces,
	)
	defer delete(surface_bytes)
	testing.expect_value(
		t,
		surface_encode_error,
		features.Surface_Artifact_Error.None,
	)
	surface_capture, surface_capture_error := surface_capture_describe(
		"stages/09-generate-features/primitives/surfaces.bin",
		{
			level = .Primitives,
			item_limit = max(u64),
			byte_limit = u64(len(surface_bytes)),
		},
		{},
		surface_bytes,
	)
	defer surface_capture_destroy(&surface_capture)
	testing.expect_value(
		t,
		surface_capture_error,
		Surface_Capture_Error.None,
	)
	surface_hash, surface_hash_ok := features.surface_result_hash(
		region_hash,
		surfaces,
	)
	testing.expect(t, surface_hash_ok)
	layer_heights := []contracts.Micrometres{200}
	skins, skin_error := features.skins_propagate(
		topology,
		regions,
		surfaces,
		layer_heights,
		polygon.CLIPPER2_PROVIDER,
		{
			fill_rule = .Even_Odd,
			top = {200, 1},
			bottom = {200, 1},
		},
	)
	defer features.skin_result_destroy(&skins)
	testing.expect_value(t, skin_error, features.Skin_Error.None)
	skin_bytes, skin_encode_error := features.skin_artifact_encode(
		surface_hash,
		schedule_artifact.result_hash,
		layer_heights,
		regions,
		surfaces,
		skins,
	)
	defer delete(skin_bytes)
	testing.expect_value(
		t,
		skin_encode_error,
		features.Skin_Artifact_Error.None,
	)
	skin_capture, skin_capture_error := skin_capture_describe(
		"stages/09-generate-features/primitives/skins.bin",
		{
			level = .Primitives,
			item_limit = max(u64),
			byte_limit = u64(len(skin_bytes)),
		},
		{},
		skin_bytes,
		surface_hash,
		schedule_artifact.result_hash,
		regions,
		surfaces,
	)
	defer skin_capture_destroy(&skin_capture)
	testing.expect_value(
		t,
		skin_capture_error,
		Skin_Capture_Error.None,
	)
	skin_hash, skin_hash_ok := features.skin_result_hash(
		surface_hash,
		schedule_artifact.result_hash,
		layer_heights,
		regions,
		surfaces,
		skins,
	)
	testing.expect(t, skin_hash_ok)

	schedule_hash_text := hex.encode(schedule_artifact.result_hash[:])
	defer delete(schedule_hash_text)
	topology_hash_text := hex.encode(topology_hash[:])
	defer delete(topology_hash_text)
	region_hash_text := hex.encode(region_hash[:])
	defer delete(region_hash_text)
	surface_hash_text := hex.encode(surface_hash[:])
	defer delete(surface_hash_text)
	skin_hash_text := hex.encode(skin_hash[:])
	defer delete(skin_hash_text)

	schedule_summary := [1]Evidence_Counter{{"scheduled_layers", 1}}
	schedule_invariants := [2]Evidence_Invariant{
		{
			"canonical_layer_schedule_result_hash",
			true,
			string(schedule_hash_text),
			string(schedule_hash_text),
		},
		{
			"source_independent_layer_schedule_replay",
			true,
			"passed",
			"passed",
		},
	}
	topology_summary := [8]Evidence_Counter{
		{"layers", 1},
		{"vertices", 12},
		{"paths", 3},
		{"path_vertex_indices", 12},
		{"path_segment_indices", 12},
		{"open_chains", 0},
		{"degenerate_loops", 0},
		{"non_manifold_vertices", 0},
	}
	topology_invariants := [2]Evidence_Invariant{
		{
			"canonical_result_hash",
			true,
			string(topology_hash_text),
			string(topology_hash_text),
		},
		{"source_independent_replay", true, "passed", "passed"},
	}
	region_summary := [5]Evidence_Counter{
		{"layers", 1},
		{"contours", 3},
		{"regions", 2},
		{"region_contour_indices", 3},
		{"holes", 1},
	}
	region_invariants := [2]Evidence_Invariant{
		{
			"canonical_result_hash",
			true,
			string(region_hash_text),
			string(region_hash_text),
		},
		{"source_independent_replay", true, "passed", "passed"},
	}
	feature_summary := [14]Evidence_Counter{
		{"surface_layers", u64(len(surfaces.layers))},
		{"surface_masks", u64(len(surfaces.masks))},
		{"surface_paths", u64(len(surfaces.paths))},
		{"surface_points", u64(len(surfaces.points))},
		{"surface_bottom_masks", surfaces.bottom_mask_count},
		{"surface_top_masks", surfaces.top_mask_count},
		{"skin_layers", u64(len(skins.layers))},
		{"skin_masks", u64(len(skins.masks))},
		{"skin_paths", u64(len(skins.paths))},
		{"skin_points", u64(len(skins.points))},
		{"skin_source_references", u64(len(skins.source_references))},
		{"skin_bottom_masks", skins.bottom_mask_count},
		{"skin_top_masks", skins.top_mask_count},
		{"skin_top_bottom_masks", skins.top_bottom_mask_count},
	}
	feature_invariants := [4]Evidence_Invariant{
		{
			"canonical_surface_result_hash",
			true,
			string(surface_hash_text),
			string(surface_hash_text),
		},
		{
			"source_independent_surface_replay",
			true,
			"passed",
			"passed",
		},
		{
			"canonical_skin_result_hash",
			true,
			string(skin_hash_text),
			string(skin_hash_text),
		},
		{
			"source_independent_skin_replay",
			true,
			"passed",
			"passed",
		},
	}

	schedule_provider, schedule_provider_ok :=
		contracts.provider_descriptor_make(
			"cpu-fixed-layer-schedule",
			{0, 1, 0},
			.Schedule_Layers,
		)
	feature_provider, feature_provider_ok :=
		contracts.provider_descriptor_make(
			"cpu-retained-features",
			{0, 1, 0},
			.Generate_Features,
		)
	testing.expect(t, schedule_provider_ok)
	testing.expect(t, feature_provider_ok)
	testing.expect_value(
		t,
		features.SCHEMA_VERSION_SURFACE_HASH,
		features.SCHEMA_VERSION_SKIN_HASH,
	)
	testing.expect_value(
		t,
		SURFACE_MANIFEST_STAGE_REVISION,
		SKIN_MANIFEST_STAGE_REVISION,
	)
	topology_provider := slicing.cpu_topology_provider_descriptor()
	region_provider := slicing.cpu_region_provider_descriptor()
	schedule_primitives := [1]Evidence_Artifact{schedule_capture.artifact}
	topology_primitives := [1]Evidence_Artifact{topology_capture.artifact}
	region_primitives := [1]Evidence_Artifact{region_capture.artifact}
	feature_primitives := [2]Evidence_Artifact{
		surface_capture.artifact,
		skin_capture.artifact,
	}
	schedule_manifest := Evidence_Manifest{
		schema_version = contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		request_hash = GOLDEN_HASH,
		stage = {
			name = "schedule-layers",
			schema_version = slicing.SCHEMA_VERSION_FIXED_LAYER_SCHEDULE_HASH,
			revision = LAYER_SCHEDULE_MANIFEST_STAGE_REVISION,
		},
		provider = {
			id = fmt.tprintf("%016x", u64(schedule_provider.id)),
			name = schedule_provider.name,
			version = "0.1.0",
		},
		source_root_id = "8877665544332211",
		source_bounds = {units = "millimetre"},
		planar_bounds = {units = "micrometre"},
		summary = schedule_summary[:],
		invariants = schedule_invariants[:],
		primitives = schedule_primitives[:],
	}
	topology_manifest := Evidence_Manifest{
		schema_version = contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		request_hash = GOLDEN_HASH,
		stage = {
			name = "reconstruct-topology",
			schema_version = slicing.SCHEMA_VERSION_TOPOLOGY_HASH,
			revision = TOPOLOGY_MANIFEST_STAGE_REVISION,
		},
		provider = {
			id = fmt.tprintf("%016x", u64(topology_provider.id)),
			name = slicing.CPU_TOPOLOGY_PROVIDER_NAME,
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
		summary = topology_summary[:],
		invariants = topology_invariants[:],
		primitives = topology_primitives[:],
	}
	region_manifest := Evidence_Manifest{
		schema_version = contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		request_hash = GOLDEN_HASH,
		stage = {
			name = "calculate-regions",
			schema_version = slicing.SCHEMA_VERSION_REGION_HASH,
			revision = REGION_MANIFEST_STAGE_REVISION,
		},
		provider = {
			id = fmt.tprintf("%016x", u64(region_provider.id)),
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
		summary = region_summary[:],
		invariants = region_invariants[:],
		primitives = region_primitives[:],
	}
	feature_manifest := Evidence_Manifest{
		schema_version = contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		request_hash = GOLDEN_HASH,
		stage = {
			name = "generate-features",
			schema_version = features.SCHEMA_VERSION_SKIN_HASH,
			revision = SKIN_MANIFEST_STAGE_REVISION,
		},
		provider = {
			id = fmt.tprintf("%016x", u64(feature_provider.id)),
			name = feature_provider.name,
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
		summary = feature_summary[:],
		invariants = feature_invariants[:],
		primitives = feature_primitives[:],
	}

	manifests := [4]Evidence_Manifest{
		schedule_manifest,
		topology_manifest,
		region_manifest,
		feature_manifest,
	}
	manifest_paths := [4]string{
		"stages/04-schedule-layers/manifest.json",
		"stages/07-reconstruct-topology/manifest.json",
		"stages/08-calculate-regions/manifest.json",
		"stages/09-generate-features/manifest.json",
	}
	manifest_bytes: [4][]u8
	manifest_artifacts: [4]Evidence_Artifact
	defer {
		for bytes in manifest_bytes {delete(bytes)}
		for &artifact in manifest_artifacts {
			evidence_artifact_destroy(&artifact)
		}
	}
	for manifest, manifest_index in manifests {
		encode_error: Evidence_Error
		manifest_bytes[manifest_index], encode_error =
			evidence_manifest_encode(manifest)
		testing.expect_value(t, encode_error, Evidence_Error.None)
		describe_error: Evidence_Artifact_Describe_Error
		manifest_artifacts[manifest_index], describe_error =
			evidence_artifact_describe(
				manifest_paths[manifest_index],
				"json",
				contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
				1,
				manifest_bytes[manifest_index],
			)
		testing.expect_value(
			t,
			describe_error,
			Evidence_Artifact_Describe_Error.None,
		)
	}

	bundle_summary_record := Evidence_Bundle_Summary{
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = GOLDEN_HASH,
		source_root_id = "8877665544332211",
		stage_count = 4,
		file_count = 5,
	}
	bundle_summary_bytes, bundle_summary_error :=
		evidence_bundle_summary_encode(bundle_summary_record)
	defer delete(bundle_summary_bytes)
	testing.expect_value(
		t,
		bundle_summary_error,
		Evidence_Bundle_Error.None,
	)
	bundle_summary, summary_describe_error := evidence_artifact_describe(
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
	stages := [4]Evidence_Bundle_Stage{
		{
			ordinal = u32(contracts.Stage_Kind.Schedule_Layers),
			stage = schedule_manifest.stage,
			provider = schedule_manifest.provider,
			manifest = manifest_artifacts[0],
		},
		{
			ordinal = u32(contracts.Stage_Kind.Reconstruct_Topology),
			stage = topology_manifest.stage,
			provider = topology_manifest.provider,
			manifest = manifest_artifacts[1],
		},
		{
			ordinal = u32(contracts.Stage_Kind.Calculate_Regions),
			stage = region_manifest.stage,
			provider = region_manifest.provider,
			manifest = manifest_artifacts[2],
		},
		{
			ordinal = u32(contracts.Stage_Kind.Generate_Features),
			stage = feature_manifest.stage,
			provider = feature_manifest.provider,
			manifest = manifest_artifacts[3],
		},
	}
	files := [5]Evidence_Artifact{
		schedule_capture.artifact,
		topology_capture.artifact,
		region_capture.artifact,
		surface_capture.artifact,
		skin_capture.artifact,
	}
	root := Evidence_Bundle_Manifest{
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = GOLDEN_HASH,
		source_root_id = "8877665544332211",
		summary = bundle_summary,
		stages = stages[:],
		files = files[:],
	}
	contents := [10]Evidence_Bundle_Content{
		{bundle_summary.path, bundle_summary_bytes},
		{manifest_artifacts[0].path, manifest_bytes[0]},
		{schedule_capture.artifact.path, schedule_capture.bytes},
		{manifest_artifacts[1].path, manifest_bytes[1]},
		{topology_capture.artifact.path, topology_capture.bytes},
		{manifest_artifacts[2].path, manifest_bytes[2]},
		{region_capture.artifact.path, region_capture.bytes},
		{manifest_artifacts[3].path, manifest_bytes[3]},
		{surface_capture.artifact.path, surface_capture.bytes},
		{skin_capture.artifact.path, skin_capture.bytes},
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
	skin_bundle_expect_replay(t, package_replay, skin_hash)

	directory_root := directory_test_root(t)
	defer {
		os2.remove_all(directory_root)
		delete(directory_root)
	}
	destination := directory_test_join(t, {directory_root, "skin-evidence"})
	defer delete(destination)
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(root, contents[:], destination),
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
	skin_bundle_expect_replay(t, directory_replay, skin_hash)
}

@(test)
skin_bundle_dependency_chain_requires_matching_retained_parents_test :: proc(
	t: ^testing.T,
) {
	replay := Evidence_Bundle_Replay{
		layer_schedule_loaded = true,
		regions_loaded = true,
		surfaces_loaded = true,
		skins_loaded = true,
	}
	replay.layer_schedule.result.layer_z = []contracts.Micrometres{100}
	replay.regions.result.layers = []slicing.Region_Layer{{}}
	replay.surfaces.result.layers = []features.Surface_Layer{{}}
	replay.skins.result.layers = []features.Skin_Layer{{}}
	replay.layer_schedule.result_hash[0] = 1
	replay.surfaces.result_hash[0] = 2
	replay.surfaces.region_hash = replay.regions.result_hash
	replay.skins.layer_schedule_hash = replay.layer_schedule.result_hash
	replay.skins.surface_hash = replay.surfaces.result_hash
	testing.expect(t, evidence_bundle_replay_dependencies_valid(replay))
	replay.skins.surface_hash[0] = 3
	testing.expect(t, !evidence_bundle_replay_dependencies_valid(replay))
	replay.skins.surface_hash = replay.surfaces.result_hash
	replay.surfaces_loaded = false
	testing.expect(t, !evidence_bundle_replay_dependencies_valid(replay))
}

@(test)
skin_bundle_stage_rejects_missing_parents_and_duplicate_primitive_test :: proc(
	t: ^testing.T,
) {
	fixture := skin_capture_test_fixture(t)
	defer skin_capture_test_fixture_destroy(&fixture)
	capture, capture_error := skin_capture_describe(
		"stages/09-generate-features/primitives/skins.bin",
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
	missing := Evidence_Bundle_Replay{}
	testing.expect_value(
		t,
		evidence_bundle_replay_stage_decode(
			&missing,
			manifest,
			capture.artifact,
			fixture.bytes,
		),
		Evidence_Bundle_Package_Error.Invalid_Content,
	)
	replay := Evidence_Bundle_Replay{
		layer_schedule_loaded = true,
		regions_loaded = true,
		surfaces_loaded = true,
	}
	replay.layer_schedule.result_hash = fixture.schedule_hash
	replay.regions.result = fixture.regions
	replay.surfaces.result_hash = fixture.surface_hash
	replay.surfaces.result = fixture.surfaces
	testing.expect_value(
		t,
		evidence_bundle_replay_stage_decode(
			&replay,
			manifest,
			capture.artifact,
			fixture.bytes,
		),
		Evidence_Bundle_Package_Error.None,
	)
	defer features.skin_artifact_destroy(&replay.skins)
	testing.expect_value(
		t,
		evidence_bundle_replay_stage_decode(
			&replay,
			manifest,
			capture.artifact,
			fixture.bytes,
		),
		Evidence_Bundle_Package_Error.Invalid_Content,
	)
}

skin_bundle_expect_replay :: proc(
	t: ^testing.T,
	replay: Evidence_Bundle_Replay,
	expected_hash: contracts.Content_Hash,
) {
	testing.expect(t, replay.layer_schedule_loaded)
	testing.expect(t, replay.topology_loaded)
	testing.expect(t, replay.regions_loaded)
	testing.expect(t, replay.surfaces_loaded)
	testing.expect(t, replay.skins_loaded)
	testing.expect_value(t, len(replay.stage_manifests), 4)
	testing.expect_value(t, len(replay.skins.layer_heights), 1)
	testing.expect_value(t, len(replay.skins.result.layers), 1)
	testing.expect(t, len(replay.skins.result.masks) > 0)
	testing.expect(t, len(replay.skins.result.source_references) > 0)
	testing.expect_value(t, replay.skins.result_hash, expected_hash)
	testing.expect_value(
		t,
		replay.skins.surface_hash,
		replay.surfaces.result_hash,
	)
	testing.expect_value(
		t,
		replay.skins.layer_schedule_hash,
		replay.layer_schedule.result_hash,
	)
}

Skin_Bundle_Schedule_Request_Hash :: contracts.Content_Hash{
	0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
	0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
	0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
	0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01,
}
