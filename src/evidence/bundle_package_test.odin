package evidence

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:os/os2"
import "core:testing"

import contracts "../contracts"
import features "../features"
import formats "../formats"
import slicing "../slicing"

@(test)
evidence_bundle_package_is_canonical_and_validates_content_test :: proc(
	t: ^testing.T,
) {
	summary_record := Evidence_Bundle_Summary{
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = GOLDEN_HASH,
		source_root_id = "8877665544332211",
		stage_count = 1,
		file_count = 2,
	}
	summary_bytes, summary_encode_error :=
		evidence_bundle_summary_encode(summary_record)
	defer delete(summary_bytes)
	testing.expect_value(
		t,
		summary_encode_error,
		Evidence_Bundle_Error.None,
	)
	primitive_text := "path-plan"
	render_text := "<svg/>\n"
	summary, summary_error := evidence_artifact_describe(
		"summary.json",
		"json",
		1,
		1,
		summary_bytes,
	)
	defer evidence_artifact_destroy(&summary)
	primitive, primitive_error := evidence_artifact_describe(
		"stages/06-intersect/primitives/segments.bin",
		"hws-segments-le",
		1,
		1,
		transmute([]u8)primitive_text,
	)
	defer evidence_artifact_destroy(&primitive)
	render, render_error := evidence_artifact_describe(
		"stages/06-intersect/renders/layer-000000.svg",
		"svg",
		1,
		1,
		transmute([]u8)render_text,
	)
	defer evidence_artifact_destroy(&render)
	testing.expect_value(t, summary_error, Evidence_Artifact_Describe_Error.None)
	testing.expect_value(
		t,
		primitive_error,
		Evidence_Artifact_Describe_Error.None,
	)
	testing.expect_value(t, render_error, Evidence_Artifact_Describe_Error.None)
	primitives := [1]Evidence_Artifact{primitive}
	renders := [1]Evidence_Artifact{render}
	stage_record := golden_manifest()
	stage_record.primitives = primitives[:]
	stage_record.renders = renders[:]
	stage_manifest_bytes, stage_manifest_error :=
		evidence_manifest_encode(stage_record)
	defer delete(stage_manifest_bytes)
	testing.expect_value(
		t,
		stage_manifest_error,
		Evidence_Error.None,
	)
	stage_manifest, stage_error := evidence_artifact_describe(
		"stages/06-intersect/manifest.json",
		"json",
		1,
		1,
		stage_manifest_bytes,
	)
	defer evidence_artifact_destroy(&stage_manifest)
	testing.expect_value(t, stage_error, Evidence_Artifact_Describe_Error.None)

	stages := [1]Evidence_Bundle_Stage{
		{
			ordinal = 6,
			stage = {
				name = "intersect",
				schema_version = 1,
				revision = 3,
			},
			provider = {
				id = "71ff96d7e1de4738",
				name = "cpu-checked",
				version = "0.1.0",
			},
			manifest = stage_manifest,
		},
	}
	files := [2]Evidence_Artifact{primitive, render}
	manifest := Evidence_Bundle_Manifest{
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = GOLDEN_HASH,
		source_root_id = "8877665544332211",
		summary = summary,
		stages = stages[:],
		files = files[:],
	}
	contents := [4]Evidence_Bundle_Content{
		{render.path, transmute([]u8)render_text},
		{summary.path, summary_bytes},
		{primitive.path, transmute([]u8)primitive_text},
		{stage_manifest.path, stage_manifest_bytes},
	}
	package_bytes, package_error := evidence_bundle_package_encode(
		manifest,
		contents[:],
	)
	defer delete(package_bytes)
	testing.expect_value(
		t,
		package_error,
		Evidence_Bundle_Package_Error.None,
	)
	testing.expect_value(
		t,
		evidence_bundle_package_validate(package_bytes),
		Evidence_Bundle_Package_Error.None,
	)
	testing.expect_value(
		t,
		evidence_bundle_package_validate(
			package_bytes,
			formats.DEFAULT_BOUNDED_ZIP_LIMITS,
			context.temp_allocator,
		),
		Evidence_Bundle_Package_Error.None,
	)
	replay, replay_error := evidence_bundle_package_replay(package_bytes)
	defer evidence_bundle_replay_destroy(&replay)
	testing.expect_value(
		t,
		replay_error,
		Evidence_Bundle_Package_Error.None,
	)
	testing.expect(t, !replay.path_plan_loaded)
	testing.expect(t, !replay.topology_loaded)
	testing.expect(t, !replay.regions_loaded)
	testing.expect_value(t, len(replay.stage_manifests), 1)
	nil_replay, nil_replay_error := evidence_bundle_package_replay(
		package_bytes,
		formats.DEFAULT_BOUNDED_ZIP_LIMITS,
		mem.nil_allocator(),
	)
	evidence_bundle_replay_destroy(&nil_replay, mem.nil_allocator())
	testing.expect_value(
		t,
		nil_replay_error,
		Evidence_Bundle_Package_Error.Allocation_Failed,
	)
	testing.expect_value(
		t,
		evidence_bundle_package_validate(
			package_bytes,
			formats.DEFAULT_BOUNDED_ZIP_LIMITS,
			mem.nil_allocator(),
		),
		Evidence_Bundle_Package_Error.Allocation_Failed,
	)
	archive, parse_error := formats.bounded_zip_parse(package_bytes)
	defer formats.bounded_zip_destroy(&archive)
	testing.expect_value(t, parse_error, formats.Bounded_Zip_Error.None)
	testing.expect_value(t, len(archive.entries), 5)
	testing.expect_value(t, archive.entries[0].name, "manifest.json")
	root_bytes, root_extract_error := formats.bounded_zip_extract(archive, 0)
	defer delete(root_bytes)
	testing.expect_value(
		t,
		root_extract_error,
		formats.Bounded_Zip_Error.None,
	)
	decoded_root, root_decode_error :=
		evidence_bundle_manifest_decode(root_bytes)
	defer evidence_bundle_manifest_destroy(&decoded_root)
	testing.expect_value(
		t,
		root_decode_error,
		Evidence_Bundle_Error.None,
	)
	testing.expect_value(t, len(decoded_root.files), 2)

	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, package_bytes)
	sha2.final(&hash_context, digest[:])
	expected_digest := [sha2.DIGEST_SIZE_256]u8{
		0x00, 0x12, 0xae, 0xd1, 0xd5, 0x58, 0xf7, 0x5c,
		0xdb, 0xbb, 0xf7, 0x93, 0x1e, 0xa3, 0xf1, 0xa6,
		0x65, 0xe1, 0xf7, 0x4e, 0x3f, 0xb1, 0xf4, 0x7f,
		0x4b, 0x0e, 0x3a, 0x9b, 0xb0, 0x41, 0xfb, 0xae,
	}
	testing.expect_value(t, digest, expected_digest)

	root_manifest_bytes, root_manifest_encode_error :=
		evidence_bundle_manifest_encode(manifest)
	defer delete(root_manifest_bytes)
	testing.expect_value(
		t,
		root_manifest_encode_error,
		Evidence_Bundle_Error.None,
	)
	hidden_text := "hidden"
	unlisted_entries := [6]formats.Bounded_Zip_Write_Entry{
		{"manifest.json", root_manifest_bytes},
		{render.path, transmute([]u8)render_text},
		{summary.path, summary_bytes},
		{primitive.path, transmute([]u8)primitive_text},
		{stage_manifest.path, stage_manifest_bytes},
		{".DS_Store", transmute([]u8)hidden_text},
	}
	unlisted_package, unlisted_write_error :=
		formats.bounded_zip_write_stored(unlisted_entries[:])
	defer delete(unlisted_package)
	testing.expect_value(
		t,
		unlisted_write_error,
		formats.Bounded_Zip_Error.None,
	)
	testing.expect_value(
		t,
		evidence_bundle_package_validate(unlisted_package),
		Evidence_Bundle_Package_Error.Invalid_Content,
	)
	missing_entries := [4]formats.Bounded_Zip_Write_Entry{
		{"manifest.json", root_manifest_bytes},
		{summary.path, summary_bytes},
		{primitive.path, transmute([]u8)primitive_text},
		{stage_manifest.path, stage_manifest_bytes},
	}
	missing_package, missing_write_error :=
		formats.bounded_zip_write_stored(missing_entries[:])
	defer delete(missing_package)
	testing.expect_value(
		t,
		missing_write_error,
		formats.Bounded_Zip_Error.None,
	)
	testing.expect_value(
		t,
		evidence_bundle_package_validate(missing_package),
		Evidence_Bundle_Package_Error.Missing_Content,
	)
	malformed_root_text := "{"
	malformed_root_entries := [1]formats.Bounded_Zip_Write_Entry{
		{"manifest.json", transmute([]u8)malformed_root_text},
	}
	malformed_root_package, malformed_root_write_error :=
		formats.bounded_zip_write_stored(malformed_root_entries[:])
	defer delete(malformed_root_package)
	testing.expect_value(
		t,
		malformed_root_write_error,
		formats.Bounded_Zip_Error.None,
	)
	testing.expect_value(
		t,
		evidence_bundle_package_validate(malformed_root_package),
		Evidence_Bundle_Package_Error.Invalid_Manifest,
	)
	oversized_root := make(
		[]u8,
		int(EVIDENCE_BUNDLE_MANIFEST_BYTE_LIMIT)+1,
	)
	defer delete(oversized_root)
	oversized_root_entries := [1]formats.Bounded_Zip_Write_Entry{
		{"manifest.json", oversized_root},
	}
	oversized_root_package, oversized_root_write_error :=
		formats.bounded_zip_write_stored(oversized_root_entries[:])
	defer delete(oversized_root_package)
	testing.expect_value(
		t,
		oversized_root_write_error,
		formats.Bounded_Zip_Error.None,
	)
	testing.expect_value(
		t,
		evidence_bundle_package_validate(oversized_root_package),
		Evidence_Bundle_Package_Error.Invalid_Manifest,
	)

	_, missing_error := evidence_bundle_package_encode(
		manifest,
		contents[:len(contents)-1],
	)
	testing.expect_value(
		t,
		missing_error,
		Evidence_Bundle_Package_Error.Missing_Content,
	)
	corrupt_contents := contents
	corrupt_text := "changed"
	corrupt_contents[2].bytes = transmute([]u8)corrupt_text
	_, corrupt_error := evidence_bundle_package_encode(
		manifest,
		corrupt_contents[:],
	)
	testing.expect_value(
		t,
		corrupt_error,
		Evidence_Bundle_Package_Error.Invalid_Content,
	)
	duplicate_contents := contents
	duplicate_contents[3] = duplicate_contents[2]
	_, duplicate_error := evidence_bundle_package_encode(
		manifest,
		duplicate_contents[:],
	)
	testing.expect_value(
		t,
		duplicate_error,
		Evidence_Bundle_Package_Error.Duplicate_Content,
	)

	mismatched_stage_record := stage_record
	mismatched_stage_record.request_hash =
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	mismatched_stage_bytes, mismatched_stage_encode_error :=
		evidence_manifest_encode(mismatched_stage_record)
	defer delete(mismatched_stage_bytes)
	testing.expect_value(
		t,
		mismatched_stage_encode_error,
		Evidence_Error.None,
	)
	mismatched_stage, mismatched_stage_describe_error :=
		evidence_artifact_describe(
			stage_manifest.path,
			stage_manifest.format,
			stage_manifest.schema_version,
			stage_manifest.item_count,
			mismatched_stage_bytes,
		)
	defer evidence_artifact_destroy(&mismatched_stage)
	testing.expect_value(
		t,
		mismatched_stage_describe_error,
		Evidence_Artifact_Describe_Error.None,
	)
	mismatched_stages := stages
	mismatched_stages[0].manifest = mismatched_stage
	mismatched_manifest := manifest
	mismatched_manifest.stages = mismatched_stages[:]
	mismatched_contents := contents
	mismatched_contents[3] = {
		mismatched_stage.path,
		mismatched_stage_bytes,
	}
	_, mismatched_error := evidence_bundle_package_encode(
		mismatched_manifest,
		mismatched_contents[:],
	)
	testing.expect_value(
		t,
		mismatched_error,
		Evidence_Bundle_Package_Error.Invalid_Content,
	)
	foreign_primitive := primitive
	foreign_primitive.path =
		"stages/10-plan-paths/primitives/foreign.bin"
	foreign_primitives := [2]Evidence_Artifact{
		primitive,
		foreign_primitive,
	}
	foreign_stage_record := stage_record
	foreign_stage_record.primitives = foreign_primitives[:]
	foreign_stage_bytes, foreign_stage_encode_error :=
		evidence_manifest_encode(foreign_stage_record)
	defer delete(foreign_stage_bytes)
	testing.expect_value(
		t,
		foreign_stage_encode_error,
		Evidence_Error.None,
	)
	foreign_files := [3]Evidence_Artifact{
		primitive,
		render,
		foreign_primitive,
	}
	foreign_root := manifest
	foreign_root.files = foreign_files[:]
	testing.expect(
		t,
		!evidence_bundle_stage_manifest_matches(
			foreign_root,
			stages[0],
			foreign_stage_bytes,
		),
	)
	mismatched_summary_record := summary_record
	mismatched_summary_record.file_count = 3
	mismatched_summary_bytes, mismatched_summary_encode_error :=
		evidence_bundle_summary_encode(mismatched_summary_record)
	defer delete(mismatched_summary_bytes)
	testing.expect_value(
		t,
		mismatched_summary_encode_error,
		Evidence_Bundle_Error.None,
	)
	mismatched_summary, mismatched_summary_error :=
		evidence_artifact_describe(
			summary.path,
			summary.format,
			summary.schema_version,
			summary.item_count,
			mismatched_summary_bytes,
		)
	defer evidence_artifact_destroy(&mismatched_summary)
	testing.expect_value(
		t,
		mismatched_summary_error,
		Evidence_Artifact_Describe_Error.None,
	)
	mismatched_summary_root := manifest
	mismatched_summary_root.summary = mismatched_summary
	mismatched_summary_contents := contents
	mismatched_summary_contents[1] = {
		mismatched_summary.path,
		mismatched_summary_bytes,
	}
	_, mismatched_summary_package_error :=
		evidence_bundle_package_encode(
			mismatched_summary_root,
			mismatched_summary_contents[:],
		)
	testing.expect_value(
		t,
		mismatched_summary_package_error,
		Evidence_Bundle_Package_Error.Invalid_Content,
	)

	corrupt_package := make([]u8, len(package_bytes))
	defer delete(corrupt_package)
	copy(corrupt_package, package_bytes)
	corrupt_package[40] = corrupt_package[40] + u8(1)
	testing.expect_value(
		t,
		evidence_bundle_package_validate(corrupt_package),
		Evidence_Bundle_Package_Error.Zip_Read_Failed,
	)
}

@(test)
evidence_bundle_package_replays_path_plan_stage_test :: proc(
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
	artifact_bytes, artifact_encode_error := path_plan_artifact_encode(
		perimeter_hash,
		infill_hash,
		result,
	)
	defer delete(artifact_bytes)
	testing.expect_value(
		t,
		artifact_encode_error,
		Path_Plan_Artifact_Error.None,
	)
	primitive, primitive_error := evidence_artifact_describe(
		"stages/10-plan-paths/primitives/path-plan.bin",
		PATH_PLAN_ARTIFACT_FORMAT,
		PATH_PLAN_ARTIFACT_SCHEMA_VERSION,
		3,
		artifact_bytes,
	)
	defer evidence_artifact_destroy(&primitive)
	testing.expect_value(
		t,
		primitive_error,
		Evidence_Artifact_Describe_Error.None,
	)
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
	primitives := [1]Evidence_Artifact{primitive}
	stage_record := Evidence_Manifest{
		schema_version = contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		request_hash = GOLDEN_HASH,
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
	stage_bytes, stage_encode_error :=
		evidence_manifest_encode(stage_record)
	defer delete(stage_bytes)
	testing.expect_value(t, stage_encode_error, Evidence_Error.None)
	stage_manifest, stage_describe_error := evidence_artifact_describe(
		"stages/10-plan-paths/manifest.json",
		"json",
		contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		1,
		stage_bytes,
	)
	defer evidence_artifact_destroy(&stage_manifest)
	testing.expect_value(
		t,
		stage_describe_error,
		Evidence_Artifact_Describe_Error.None,
	)
	summary_record := Evidence_Bundle_Summary{
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = GOLDEN_HASH,
		source_root_id = "8877665544332211",
		stage_count = 1,
		file_count = 1,
	}
	summary_bytes, summary_encode_error :=
		evidence_bundle_summary_encode(summary_record)
	defer delete(summary_bytes)
	testing.expect_value(
		t,
		summary_encode_error,
		Evidence_Bundle_Error.None,
	)
	bundle_summary, summary_error := evidence_artifact_describe(
		"summary.json",
		"json",
		EVIDENCE_BUNDLE_SCHEMA_VERSION,
		1,
		summary_bytes,
	)
	defer evidence_artifact_destroy(&bundle_summary)
	testing.expect_value(
		t,
		summary_error,
		Evidence_Artifact_Describe_Error.None,
	)
	stages := [1]Evidence_Bundle_Stage{
		{
			ordinal = 10,
			stage = stage_record.stage,
			provider = stage_record.provider,
			manifest = stage_manifest,
		},
	}
	files := [1]Evidence_Artifact{primitive}
	root := Evidence_Bundle_Manifest{
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = GOLDEN_HASH,
		source_root_id = stage_record.source_root_id,
		summary = bundle_summary,
		stages = stages[:],
		files = files[:],
	}
	contents := [3]Evidence_Bundle_Content{
		{bundle_summary.path, summary_bytes},
		{stage_manifest.path, stage_bytes},
		{primitive.path, artifact_bytes},
	}
	package_bytes, package_error :=
		evidence_bundle_package_encode(root, contents[:])
	defer delete(package_bytes)
	testing.expect_value(
		t,
		package_error,
		Evidence_Bundle_Package_Error.None,
	)
	testing.expect_value(
		t,
		evidence_bundle_package_validate(package_bytes),
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
	testing.expect(t, package_replay.path_plan_loaded)
	testing.expect(t, !package_replay.topology_loaded)
	testing.expect(t, !package_replay.regions_loaded)
	testing.expect_value(t, len(package_replay.stage_manifests), 1)
	testing.expect_value(t, len(package_replay.path_plan.result.layers), 1)
	testing.expect_value(t, len(package_replay.path_plan.result.paths), 1)
	testing.expect_value(t, len(package_replay.path_plan.result.moves), 1)
	testing.expect_value(
		t,
		evidence_bundle_package_validate(
			package_bytes,
			formats.DEFAULT_BOUNDED_ZIP_LIMITS,
			context.temp_allocator,
		),
		Evidence_Bundle_Package_Error.None,
	)
	directory_root := directory_test_root(t)
	defer {
		os2.remove_all(directory_root)
		delete(directory_root)
	}
	directory_destination :=
		directory_test_join(t, {directory_root, "path-plan"})
	defer delete(directory_destination)
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(
			root,
			contents[:],
			directory_destination,
		),
		Evidence_Bundle_Directory_Error.None,
	)
	directory_replay, directory_replay_error :=
		evidence_bundle_directory_replay(directory_destination)
	defer evidence_bundle_replay_destroy(&directory_replay)
	testing.expect_value(
		t,
		directory_replay_error,
		Evidence_Bundle_Directory_Error.None,
	)
	testing.expect(t, directory_replay.path_plan_loaded)
	testing.expect(t, !directory_replay.topology_loaded)
	testing.expect(t, !directory_replay.regions_loaded)
	testing.expect_value(t, len(directory_replay.stage_manifests), 1)

	corrupt_artifact_bytes := make([]u8, len(artifact_bytes))
	defer delete(corrupt_artifact_bytes)
	copy(corrupt_artifact_bytes, artifact_bytes)
	corrupt_artifact_bytes[200] = corrupt_artifact_bytes[200] ~ 1
	corrupt_primitive, corrupt_primitive_error :=
		evidence_artifact_describe(
			primitive.path,
			primitive.format,
			primitive.schema_version,
			primitive.item_count,
			corrupt_artifact_bytes,
		)
	defer evidence_artifact_destroy(&corrupt_primitive)
	testing.expect_value(
		t,
		corrupt_primitive_error,
		Evidence_Artifact_Describe_Error.None,
	)
	corrupt_primitives := [1]Evidence_Artifact{corrupt_primitive}
	corrupt_stage_record := stage_record
	corrupt_stage_record.primitives = corrupt_primitives[:]
	corrupt_stage_bytes, corrupt_stage_encode_error :=
		evidence_manifest_encode(corrupt_stage_record)
	defer delete(corrupt_stage_bytes)
	testing.expect_value(
		t,
		corrupt_stage_encode_error,
		Evidence_Error.None,
	)
	corrupt_stage_manifest, corrupt_stage_error :=
		evidence_artifact_describe(
			stage_manifest.path,
			stage_manifest.format,
			stage_manifest.schema_version,
			stage_manifest.item_count,
			corrupt_stage_bytes,
		)
	defer evidence_artifact_destroy(&corrupt_stage_manifest)
	testing.expect_value(
		t,
		corrupt_stage_error,
		Evidence_Artifact_Describe_Error.None,
	)
	corrupt_stages := stages
	corrupt_stages[0].manifest = corrupt_stage_manifest
	corrupt_files := [1]Evidence_Artifact{corrupt_primitive}
	corrupt_root := root
	corrupt_root.stages = corrupt_stages[:]
	corrupt_root.files = corrupt_files[:]
	corrupt_contents := [3]Evidence_Bundle_Content{
		{bundle_summary.path, summary_bytes},
		{corrupt_stage_manifest.path, corrupt_stage_bytes},
		{corrupt_primitive.path, corrupt_artifact_bytes},
	}
	corrupt_package, corrupt_package_error :=
		evidence_bundle_package_encode(corrupt_root, corrupt_contents[:])
	defer delete(corrupt_package)
	testing.expect_value(
		t,
		corrupt_package_error,
		Evidence_Bundle_Package_Error.None,
	)
	testing.expect_value(
		t,
		evidence_bundle_package_validate(corrupt_package),
		Evidence_Bundle_Package_Error.Invalid_Content,
	)
	corrupt_directory_destination :=
		directory_test_join(t, {directory_root, "corrupt-path-plan"})
	defer delete(corrupt_directory_destination)
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(
			corrupt_root,
			corrupt_contents[:],
			corrupt_directory_destination,
		),
		Evidence_Bundle_Directory_Error.Validation_Failed,
	)
	testing.expect(
		t,
		!directory_test_path_exists(corrupt_directory_destination),
	)
	testing.expect_value(
		t,
		directory_test_staging_count(t, directory_root),
		0,
	)
}

@(test)
evidence_bundle_package_replays_topology_stage_test :: proc(
	t: ^testing.T,
) {
	snapped_hash, source_segment_count, result :=
		topology_artifact_test_fixture()
	defer slicing.topology_result_destroy(&result)
	result_hash, result_hash_ok := slicing.topology_result_hash(
		snapped_hash,
		source_segment_count,
		result,
	)
	testing.expect(t, result_hash_ok)
	result_hash_text := hex.encode(result_hash[:])
	defer delete(result_hash_text)
	artifact_bytes, artifact_encode_error := topology_artifact_encode(
		snapped_hash,
		source_segment_count,
		result,
	)
	defer delete(artifact_bytes)
	testing.expect_value(
		t,
		artifact_encode_error,
		Topology_Artifact_Error.None,
	)
	primitive, primitive_error := evidence_artifact_describe(
		"stages/07-reconstruct-topology/primitives/topology.bin",
		TOPOLOGY_ARTIFACT_FORMAT,
		TOPOLOGY_ARTIFACT_SCHEMA_VERSION,
		39,
		artifact_bytes,
	)
	defer evidence_artifact_destroy(&primitive)
	testing.expect_value(
		t,
		primitive_error,
		Evidence_Artifact_Describe_Error.None,
	)
	summary := [8]Evidence_Counter{
		{"layers", 1},
		{"vertices", 10},
		{"paths", 6},
		{"path_vertex_indices", 13},
		{"path_segment_indices", 9},
		{"open_chains", 4},
		{"degenerate_loops", 1},
		{"non_manifold_vertices", 1},
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
	primitives := [1]Evidence_Artifact{primitive}
	provider := slicing.cpu_topology_provider_descriptor()
	stage_record := Evidence_Manifest{
		schema_version = contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		request_hash = GOLDEN_HASH,
		stage = {
			name = "reconstruct-topology",
			schema_version = slicing.SCHEMA_VERSION_TOPOLOGY_HASH,
			revision = TOPOLOGY_MANIFEST_STAGE_REVISION,
		},
		provider = {
			id = fmt.tprintf("%016x", u64(provider.id)),
			name = slicing.CPU_TOPOLOGY_PROVIDER_NAME,
			version = "0.1.0",
		},
		source_root_id = "8877665544332211",
		source_bounds = {units = "millimetre"},
		planar_bounds = {
			valid = true,
			minimum = {0, 0},
			maximum = {11_000, 6_000},
			units = "micrometre",
		},
		summary = summary[:],
		invariants = invariants[:],
		primitives = primitives[:],
	}
	stage_bytes, stage_encode_error :=
		evidence_manifest_encode(stage_record)
	defer delete(stage_bytes)
	testing.expect_value(t, stage_encode_error, Evidence_Error.None)
	stage_manifest, stage_describe_error := evidence_artifact_describe(
		"stages/07-reconstruct-topology/manifest.json",
		"json",
		contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
		1,
		stage_bytes,
	)
	defer evidence_artifact_destroy(&stage_manifest)
	testing.expect_value(
		t,
		stage_describe_error,
		Evidence_Artifact_Describe_Error.None,
	)
	summary_record := Evidence_Bundle_Summary{
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = GOLDEN_HASH,
		source_root_id = stage_record.source_root_id,
		stage_count = 1,
		file_count = 1,
	}
	summary_bytes, summary_encode_error :=
		evidence_bundle_summary_encode(summary_record)
	defer delete(summary_bytes)
	testing.expect_value(
		t,
		summary_encode_error,
		Evidence_Bundle_Error.None,
	)
	bundle_summary, summary_error := evidence_artifact_describe(
		"summary.json",
		"json",
		EVIDENCE_BUNDLE_SCHEMA_VERSION,
		1,
		summary_bytes,
	)
	defer evidence_artifact_destroy(&bundle_summary)
	testing.expect_value(
		t,
		summary_error,
		Evidence_Artifact_Describe_Error.None,
	)
	stages := [1]Evidence_Bundle_Stage{
		{
			ordinal = 7,
			stage = stage_record.stage,
			provider = stage_record.provider,
			manifest = stage_manifest,
		},
	}
	files := [1]Evidence_Artifact{primitive}
	root := Evidence_Bundle_Manifest{
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = GOLDEN_HASH,
		source_root_id = stage_record.source_root_id,
		summary = bundle_summary,
		stages = stages[:],
		files = files[:],
	}
	contents := [3]Evidence_Bundle_Content{
		{bundle_summary.path, summary_bytes},
		{stage_manifest.path, stage_bytes},
		{primitive.path, artifact_bytes},
	}
	package_bytes, package_error :=
		evidence_bundle_package_encode(root, contents[:])
	defer delete(package_bytes)
	testing.expect_value(
		t,
		package_error,
		Evidence_Bundle_Package_Error.None,
	)
	testing.expect_value(
		t,
		evidence_bundle_package_validate(package_bytes),
		Evidence_Bundle_Package_Error.None,
	)
	directory_root := directory_test_root(t)
	defer {
		os2.remove_all(directory_root)
		delete(directory_root)
	}
	directory_destination :=
		directory_test_join(t, {directory_root, "topology"})
	defer delete(directory_destination)
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(
			root,
			contents[:],
			directory_destination,
		),
		Evidence_Bundle_Directory_Error.None,
	)

	corrupt_artifact_bytes := make([]u8, len(artifact_bytes))
	defer delete(corrupt_artifact_bytes)
	copy(corrupt_artifact_bytes, artifact_bytes)
	first_vertex_degree_offset :=
		int(TOPOLOGY_ARTIFACT_HEADER_SIZE)+
		int(TOPOLOGY_ARTIFACT_LAYER_SIZE)+12
	topology_artifact_put_u32(
		corrupt_artifact_bytes,
		first_vertex_degree_offset,
		3,
	)
	corrupt_primitive, corrupt_primitive_error :=
		evidence_artifact_describe(
			primitive.path,
			primitive.format,
			primitive.schema_version,
			primitive.item_count,
			corrupt_artifact_bytes,
		)
	defer evidence_artifact_destroy(&corrupt_primitive)
	testing.expect_value(
		t,
		corrupt_primitive_error,
		Evidence_Artifact_Describe_Error.None,
	)
	corrupt_primitives := [1]Evidence_Artifact{corrupt_primitive}
	corrupt_stage_record := stage_record
	corrupt_stage_record.primitives = corrupt_primitives[:]
	corrupt_stage_bytes, corrupt_stage_encode_error :=
		evidence_manifest_encode(corrupt_stage_record)
	defer delete(corrupt_stage_bytes)
	testing.expect_value(
		t,
		corrupt_stage_encode_error,
		Evidence_Error.None,
	)
	corrupt_stage_manifest, corrupt_stage_error :=
		evidence_artifact_describe(
			stage_manifest.path,
			stage_manifest.format,
			stage_manifest.schema_version,
			stage_manifest.item_count,
			corrupt_stage_bytes,
		)
	defer evidence_artifact_destroy(&corrupt_stage_manifest)
	testing.expect_value(
		t,
		corrupt_stage_error,
		Evidence_Artifact_Describe_Error.None,
	)
	corrupt_stages := stages
	corrupt_stages[0].manifest = corrupt_stage_manifest
	corrupt_files := [1]Evidence_Artifact{corrupt_primitive}
	corrupt_root := root
	corrupt_root.stages = corrupt_stages[:]
	corrupt_root.files = corrupt_files[:]
	corrupt_contents := [3]Evidence_Bundle_Content{
		{bundle_summary.path, summary_bytes},
		{corrupt_stage_manifest.path, corrupt_stage_bytes},
		{corrupt_primitive.path, corrupt_artifact_bytes},
	}
	corrupt_package, corrupt_package_error :=
		evidence_bundle_package_encode(corrupt_root, corrupt_contents[:])
	defer delete(corrupt_package)
	testing.expect_value(
		t,
		corrupt_package_error,
		Evidence_Bundle_Package_Error.None,
	)
	testing.expect_value(
		t,
		evidence_bundle_package_validate(corrupt_package),
		Evidence_Bundle_Package_Error.Invalid_Content,
	)
	corrupt_directory_destination :=
		directory_test_join(t, {directory_root, "corrupt-topology"})
	defer delete(corrupt_directory_destination)
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(
			corrupt_root,
			corrupt_contents[:],
			corrupt_directory_destination,
		),
		Evidence_Bundle_Directory_Error.Validation_Failed,
	)
	testing.expect(
		t,
		!directory_test_path_exists(corrupt_directory_destination),
	)
	testing.expect_value(
		t,
		directory_test_staging_count(t, directory_root),
		0,
	)
}

@(test)
evidence_bundle_package_replays_region_after_topology_test :: proc(
	t: ^testing.T,
) {
	topology_hash, topology, regions := region_artifact_test_fixture()
	defer slicing.topology_result_destroy(&topology)
	defer slicing.region_result_destroy(&regions)
	snapped_hash: contracts.Content_Hash
	for &byte, byte_index in snapped_hash {
		byte = u8(0x80+byte_index)
	}
	topology_capture, topology_capture_error :=
		topology_capture_encode(
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
	topology_hash_text := hex.encode(topology_hash[:])
	defer delete(topology_hash_text)
	region_hash_text := hex.encode(region_hash[:])
	defer delete(region_hash_text)
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
	region_summary := [5]Evidence_Counter{
		{"layers", 1},
		{"contours", 3},
		{"regions", 2},
		{"region_contour_indices", 3},
		{"holes", 1},
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
	region_invariants := [2]Evidence_Invariant{
		{
			"canonical_result_hash",
			true,
			string(region_hash_text),
			string(region_hash_text),
		},
		{"source_independent_replay", true, "passed", "passed"},
	}
	topology_primitives :=
		[1]Evidence_Artifact{topology_capture.artifact}
	region_primitives := [1]Evidence_Artifact{region_capture.artifact}
	topology_provider := slicing.cpu_topology_provider_descriptor()
	region_provider := slicing.cpu_region_provider_descriptor()
	topology_stage_record := Evidence_Manifest{
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
	region_stage_record := Evidence_Manifest{
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
	topology_stage_bytes, topology_stage_encode_error :=
		evidence_manifest_encode(topology_stage_record)
	defer delete(topology_stage_bytes)
	region_stage_bytes, region_stage_encode_error :=
		evidence_manifest_encode(region_stage_record)
	defer delete(region_stage_bytes)
	testing.expect_value(
		t,
		topology_stage_encode_error,
		Evidence_Error.None,
	)
	testing.expect_value(
		t,
		region_stage_encode_error,
		Evidence_Error.None,
	)
	topology_stage_manifest, topology_stage_describe_error :=
		evidence_artifact_describe(
			"stages/07-reconstruct-topology/manifest.json",
			"json",
			contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
			1,
			topology_stage_bytes,
		)
	defer evidence_artifact_destroy(&topology_stage_manifest)
	region_stage_manifest, region_stage_describe_error :=
		evidence_artifact_describe(
			"stages/08-calculate-regions/manifest.json",
			"json",
			contracts.SCHEMA_VERSION_DEBUG_EVIDENCE,
			1,
			region_stage_bytes,
		)
	defer evidence_artifact_destroy(&region_stage_manifest)
	testing.expect_value(
		t,
		topology_stage_describe_error,
		Evidence_Artifact_Describe_Error.None,
	)
	testing.expect_value(
		t,
		region_stage_describe_error,
		Evidence_Artifact_Describe_Error.None,
	)
	summary_record := Evidence_Bundle_Summary{
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = GOLDEN_HASH,
		source_root_id = "8877665544332211",
		stage_count = 2,
		file_count = 2,
	}
	summary_bytes, summary_encode_error :=
		evidence_bundle_summary_encode(summary_record)
	defer delete(summary_bytes)
	testing.expect_value(
		t,
		summary_encode_error,
		Evidence_Bundle_Error.None,
	)
	bundle_summary, bundle_summary_error := evidence_artifact_describe(
		"summary.json",
		"json",
		EVIDENCE_BUNDLE_SCHEMA_VERSION,
		1,
		summary_bytes,
	)
	defer evidence_artifact_destroy(&bundle_summary)
	testing.expect_value(
		t,
		bundle_summary_error,
		Evidence_Artifact_Describe_Error.None,
	)
	stages := [2]Evidence_Bundle_Stage{
		{
			ordinal = 7,
			stage = topology_stage_record.stage,
			provider = topology_stage_record.provider,
			manifest = topology_stage_manifest,
		},
		{
			ordinal = 8,
			stage = region_stage_record.stage,
			provider = region_stage_record.provider,
			manifest = region_stage_manifest,
		},
	}
	files := [2]Evidence_Artifact{
		topology_capture.artifact,
		region_capture.artifact,
	}
	root := Evidence_Bundle_Manifest{
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = GOLDEN_HASH,
		source_root_id = "8877665544332211",
		summary = bundle_summary,
		stages = stages[:],
		files = files[:],
	}
	contents := [5]Evidence_Bundle_Content{
		{bundle_summary.path, summary_bytes},
		{topology_stage_manifest.path, topology_stage_bytes},
		{topology_capture.artifact.path, topology_capture.bytes},
		{region_stage_manifest.path, region_stage_bytes},
		{region_capture.artifact.path, region_capture.bytes},
	}
	package_bytes, package_error :=
		evidence_bundle_package_encode(root, contents[:])
	defer delete(package_bytes)
	testing.expect_value(
		t,
		package_error,
		Evidence_Bundle_Package_Error.None,
	)
	testing.expect_value(
		t,
		evidence_bundle_package_validate(package_bytes),
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
	testing.expect(t, package_replay.topology_loaded)
	testing.expect(t, package_replay.regions_loaded)
	testing.expect(t, !package_replay.path_plan_loaded)
	testing.expect_value(t, len(package_replay.stage_manifests), 2)
	testing.expect_value(
		t,
		len(package_replay.topology.result.paths),
		3,
	)
	testing.expect_value(
		t,
		len(package_replay.regions.result.contours),
		3,
	)
	testing.expect_value(
		t,
		len(package_replay.regions.result.regions),
		2,
	)
	directory_root := directory_test_root(t)
	defer {
		os2.remove_all(directory_root)
		delete(directory_root)
	}
	directory_destination :=
		directory_test_join(t, {directory_root, "regions"})
	defer delete(directory_destination)
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(
			root,
			contents[:],
			directory_destination,
		),
		Evidence_Bundle_Directory_Error.None,
	)
	directory_replay, directory_replay_error :=
		evidence_bundle_directory_replay(directory_destination)
	defer evidence_bundle_replay_destroy(&directory_replay)
	testing.expect_value(
		t,
		directory_replay_error,
		Evidence_Bundle_Directory_Error.None,
	)
	testing.expect(t, directory_replay.topology_loaded)
	testing.expect(t, directory_replay.regions_loaded)
	testing.expect(t, !directory_replay.path_plan_loaded)
	testing.expect_value(t, len(directory_replay.stage_manifests), 2)

	corrupt_region_bytes := make([]u8, len(region_capture.bytes))
	defer delete(corrupt_region_bytes)
	copy(corrupt_region_bytes, region_capture.bytes)
	first_contour_path_offset :=
		int(REGION_ARTIFACT_HEADER_SIZE)+
		int(REGION_ARTIFACT_LAYER_SIZE)+8
	topology_artifact_put_u32(
		corrupt_region_bytes,
		first_contour_path_offset,
		99,
	)
	corrupt_region_primitive, corrupt_primitive_error :=
		evidence_artifact_describe(
			region_capture.artifact.path,
			region_capture.artifact.format,
			region_capture.artifact.schema_version,
			region_capture.artifact.item_count,
			corrupt_region_bytes,
		)
	defer evidence_artifact_destroy(&corrupt_region_primitive)
	testing.expect_value(
		t,
		corrupt_primitive_error,
		Evidence_Artifact_Describe_Error.None,
	)
	corrupt_region_primitives :=
		[1]Evidence_Artifact{corrupt_region_primitive}
	corrupt_region_stage_record := region_stage_record
	corrupt_region_stage_record.primitives =
		corrupt_region_primitives[:]
	corrupt_region_stage_bytes, corrupt_stage_encode_error :=
		evidence_manifest_encode(corrupt_region_stage_record)
	defer delete(corrupt_region_stage_bytes)
	testing.expect_value(
		t,
		corrupt_stage_encode_error,
		Evidence_Error.None,
	)
	corrupt_region_stage_manifest, corrupt_stage_describe_error :=
		evidence_artifact_describe(
			region_stage_manifest.path,
			region_stage_manifest.format,
			region_stage_manifest.schema_version,
			region_stage_manifest.item_count,
			corrupt_region_stage_bytes,
		)
	defer evidence_artifact_destroy(&corrupt_region_stage_manifest)
	testing.expect_value(
		t,
		corrupt_stage_describe_error,
		Evidence_Artifact_Describe_Error.None,
	)
	corrupt_stages := stages
	corrupt_stages[1].manifest = corrupt_region_stage_manifest
	corrupt_files := [2]Evidence_Artifact{
		topology_capture.artifact,
		corrupt_region_primitive,
	}
	corrupt_root := root
	corrupt_root.stages = corrupt_stages[:]
	corrupt_root.files = corrupt_files[:]
	corrupt_contents := [5]Evidence_Bundle_Content{
		{bundle_summary.path, summary_bytes},
		{topology_stage_manifest.path, topology_stage_bytes},
		{topology_capture.artifact.path, topology_capture.bytes},
		{corrupt_region_stage_manifest.path, corrupt_region_stage_bytes},
		{corrupt_region_primitive.path, corrupt_region_bytes},
	}
	corrupt_package, corrupt_package_error :=
		evidence_bundle_package_encode(
			corrupt_root,
			corrupt_contents[:],
		)
	defer delete(corrupt_package)
	testing.expect_value(
		t,
		corrupt_package_error,
		Evidence_Bundle_Package_Error.None,
	)
	testing.expect_value(
		t,
		evidence_bundle_package_validate(corrupt_package),
		Evidence_Bundle_Package_Error.Invalid_Content,
	)
	corrupt_destination :=
		directory_test_join(t, {directory_root, "corrupt-regions"})
	defer delete(corrupt_destination)
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(
			corrupt_root,
			corrupt_contents[:],
			corrupt_destination,
		),
		Evidence_Bundle_Directory_Error.Validation_Failed,
	)
	testing.expect(t, !directory_test_path_exists(corrupt_destination))
}
