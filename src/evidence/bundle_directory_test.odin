package evidence

import "core:fmt"
import "core:os"
import "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import formats "../formats"

Directory_Test_Fixture :: struct {
	summary_bytes:        []u8,
	stage_manifest_bytes: []u8,
	summary:              Evidence_Artifact,
	primitive:            Evidence_Artifact,
	render:               Evidence_Artifact,
	stage_manifest:       Evidence_Artifact,
	stages:               [1]Evidence_Bundle_Stage,
	files:                [2]Evidence_Artifact,
	contents:             [4]Evidence_Bundle_Content,
	manifest:             Evidence_Bundle_Manifest,
}

directory_test_fixture_init :: proc(
	fixture: ^Directory_Test_Fixture,
) -> bool {
	summary_record := Evidence_Bundle_Summary{
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = GOLDEN_HASH,
		source_root_id = "8877665544332211",
		stage_count = 1,
		file_count = 2,
	}
	summary_error: Evidence_Bundle_Error
	fixture.summary_bytes, summary_error =
		evidence_bundle_summary_encode(summary_record)
	if summary_error != .None {return false}
	primitive_text := "path-plan"
	render_text := "<svg/>\n"
	describe_error: Evidence_Artifact_Describe_Error
	fixture.summary, describe_error = evidence_artifact_describe(
		"summary.json",
		"json",
		EVIDENCE_BUNDLE_SCHEMA_VERSION,
		1,
		fixture.summary_bytes,
	)
	if describe_error != .None {return false}
	fixture.primitive, describe_error = evidence_artifact_describe(
		"stages/06-intersect/primitives/segments.bin",
		"hws-segments-le",
		1,
		1,
		transmute([]u8)primitive_text,
	)
	if describe_error != .None {return false}
	fixture.render, describe_error = evidence_artifact_describe(
		"stages/06-intersect/renders/layer-000000.svg",
		"svg",
		1,
		1,
		transmute([]u8)render_text,
	)
	if describe_error != .None {return false}
	primitives := [1]Evidence_Artifact{fixture.primitive}
	renders := [1]Evidence_Artifact{fixture.render}
	stage_record := golden_manifest()
	stage_record.primitives = primitives[:]
	stage_record.renders = renders[:]
	stage_manifest_error: Evidence_Error
	fixture.stage_manifest_bytes, stage_manifest_error =
		evidence_manifest_encode(stage_record)
	if stage_manifest_error != .None {return false}
	fixture.stage_manifest, describe_error = evidence_artifact_describe(
		"stages/06-intersect/manifest.json",
		"json",
		1,
		1,
		fixture.stage_manifest_bytes,
	)
	if describe_error != .None {return false}
	directory_test_fixture_bind(fixture)
	return true
}

directory_test_fixture_bind :: proc(fixture: ^Directory_Test_Fixture) {
	fixture.stages[0] = {
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
		manifest = fixture.stage_manifest,
	}
	fixture.files = {fixture.primitive, fixture.render}
	fixture.manifest = {
		schema_version = EVIDENCE_BUNDLE_SCHEMA_VERSION,
		request_hash = GOLDEN_HASH,
		source_root_id = "8877665544332211",
		summary = fixture.summary,
		stages = fixture.stages[:],
		files = fixture.files[:],
	}
	primitive_text := "path-plan"
	render_text := "<svg/>\n"
	fixture.contents = {
		{fixture.render.path, transmute([]u8)render_text},
		{fixture.summary.path, fixture.summary_bytes},
		{fixture.primitive.path, transmute([]u8)primitive_text},
		{fixture.stage_manifest.path, fixture.stage_manifest_bytes},
	}
}

directory_test_fixture_destroy :: proc(fixture: ^Directory_Test_Fixture) {
	delete(fixture.summary_bytes)
	delete(fixture.stage_manifest_bytes)
	evidence_artifact_destroy(&fixture.summary)
	evidence_artifact_destroy(&fixture.primitive)
	evidence_artifact_destroy(&fixture.render)
	evidence_artifact_destroy(&fixture.stage_manifest)
	fixture^ = {}
}

directory_test_root :: proc(t: ^testing.T) -> string {
	path, error := os2.make_directory_temp(
		"/tmp",
		"hw-slicer-evidence-directory-*",
		context.allocator,
	)
	testing.expect(t, error == nil)
	return path
}

directory_test_join :: proc(t: ^testing.T, parts: []string) -> string {
	path, error := filepath.join(parts)
	testing.expect(t, error == nil)
	return path
}

directory_test_path_exists :: proc(path: string) -> bool {
	info, error := os.lstat(path)
	if error != nil {return false}
	os.file_info_delete(info)
	return true
}

directory_test_staging_count :: proc(t: ^testing.T, path: string) -> int {
	handle, open_error := os.open(path)
	testing.expect(t, open_error == nil)
	if open_error != nil {return -1}
	defer os.close(handle)
	infos, read_error := os.read_dir(handle, -1)
	testing.expect(t, read_error == nil)
	if read_error != nil {return -1}
	defer os.file_info_slice_delete(infos)
	count := 0
	for info in infos {
		if strings.has_prefix(info.name, EVIDENCE_BUNDLE_STAGING_PREFIX) {
			count += 1
		}
	}
	return count
}

@(test)
evidence_bundle_directory_publishes_and_validates_exact_tree_test :: proc(
	t: ^testing.T,
) {
	fixture: Directory_Test_Fixture
	testing.expect(t, directory_test_fixture_init(&fixture))
	defer directory_test_fixture_destroy(&fixture)
	root := directory_test_root(t)
	defer {
		os2.remove_all(root)
		delete(root)
	}
	destination := directory_test_join(t, {root, "bundle"})
	defer delete(destination)
	publish_error := evidence_bundle_directory_publish(
		fixture.manifest,
		fixture.contents[:],
		destination,
	)
	testing.expect_value(
		t,
		publish_error,
		Evidence_Bundle_Directory_Error.None,
	)
	testing.expect_value(
		t,
		evidence_bundle_directory_validate(destination),
		Evidence_Bundle_Directory_Error.None,
	)
	testing.expect_value(t, directory_test_staging_count(t, root), 0)

	reordered_destination :=
		directory_test_join(t, {root, "bundle-reordered"})
	defer delete(reordered_destination)
	reordered_contents := [4]Evidence_Bundle_Content{
		fixture.contents[2],
		fixture.contents[3],
		fixture.contents[0],
		fixture.contents[1],
	}
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(
			fixture.manifest,
			reordered_contents[:],
			reordered_destination,
		),
		Evidence_Bundle_Directory_Error.None,
	)
	for content in fixture.contents {
		first_path := directory_test_join(
			t,
			{destination, content.path},
		)
		second_path := directory_test_join(
			t,
			{reordered_destination, content.path},
		)
		first_bytes, first_ok := os.read_entire_file(first_path)
		second_bytes, second_ok := os.read_entire_file(second_path)
		testing.expect(t, first_ok && second_ok)
		testing.expect(
			t,
			evidence_bundle_bytes_equal(first_bytes, second_bytes),
		)
		delete(first_bytes)
		delete(second_bytes)
		delete(first_path)
		delete(second_path)
	}
}

@(test)
evidence_bundle_directory_preserves_existing_destination_test :: proc(
	t: ^testing.T,
) {
	fixture: Directory_Test_Fixture
	testing.expect(t, directory_test_fixture_init(&fixture))
	defer directory_test_fixture_destroy(&fixture)
	root := directory_test_root(t)
	defer {
		os2.remove_all(root)
		delete(root)
	}
	destination := directory_test_join(t, {root, "bundle"})
	defer delete(destination)
	testing.expect(t, os.make_directory(destination, 0o700) == nil)
	marker_path := directory_test_join(t, {destination, "marker"})
	defer delete(marker_path)
	marker_text := "preserve"
	marker_bytes := transmute([]u8)marker_text
	testing.expect(t, os.write_entire_file(marker_path, marker_bytes))
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(
			fixture.manifest,
			fixture.contents[:],
			destination,
		),
		Evidence_Bundle_Directory_Error.Destination_Exists,
	)
	actual_marker, marker_ok := os.read_entire_file(marker_path)
	defer delete(actual_marker)
	testing.expect(t, marker_ok)
	testing.expect(
		t,
		evidence_bundle_bytes_equal(actual_marker, marker_bytes),
	)
	testing.expect_value(t, directory_test_staging_count(t, root), 0)
}

@(test)
evidence_bundle_directory_cleans_every_injected_failure_test :: proc(
	t: ^testing.T,
) {
	fixture: Directory_Test_Fixture
	testing.expect(t, directory_test_fixture_init(&fixture))
	defer directory_test_fixture_destroy(&fixture)
	root := directory_test_root(t)
	defer {
		os2.remove_all(root)
		delete(root)
	}
	for file_count in 1..=u64(5) {
		name := fmt.aprintf("bundle-%d", file_count)
		destination := directory_test_join(t, {root, name})
		error := evidence_bundle_directory_publish(
			fixture.manifest,
			fixture.contents[:],
			destination,
			{fail_after_file_count = file_count},
		)
		testing.expect_value(
			t,
			error,
			Evidence_Bundle_Directory_Error.Injected_Failure,
		)
		testing.expect(t, !directory_test_path_exists(destination))
		testing.expect_value(t, directory_test_staging_count(t, root), 0)
		delete(destination)
		delete(name)
	}
	destination := directory_test_join(t, {root, "before-rename"})
	defer delete(destination)
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(
			fixture.manifest,
			fixture.contents[:],
			destination,
			{fail_before_rename = true},
		),
		Evidence_Bundle_Directory_Error.Injected_Failure,
	)
	testing.expect(t, !directory_test_path_exists(destination))
	testing.expect_value(t, directory_test_staging_count(t, root), 0)
}

@(test)
evidence_bundle_directory_rejects_invalid_content_before_staging_test :: proc(
	t: ^testing.T,
) {
	fixture: Directory_Test_Fixture
	testing.expect(t, directory_test_fixture_init(&fixture))
	defer directory_test_fixture_destroy(&fixture)
	root := directory_test_root(t)
	defer {
		os2.remove_all(root)
		delete(root)
	}
	destination := directory_test_join(t, {root, "bundle"})
	defer delete(destination)
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(
			fixture.manifest,
			fixture.contents[:len(fixture.contents)-1],
			destination,
		),
		Evidence_Bundle_Directory_Error.Missing_Content,
	)
	corrupt := fixture.contents
	corrupt_text_value := "changed"
	corrupt_text := transmute([]u8)corrupt_text_value
	corrupt[2].bytes = corrupt_text
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(
			fixture.manifest,
			corrupt[:],
			destination,
		),
		Evidence_Bundle_Directory_Error.Invalid_Content,
	)
	duplicate := fixture.contents
	duplicate[3] = duplicate[2]
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(
			fixture.manifest,
			duplicate[:],
			destination,
		),
		Evidence_Bundle_Directory_Error.Invalid_Content,
	)
	testing.expect(t, !directory_test_path_exists(destination))
	testing.expect_value(t, directory_test_staging_count(t, root), 0)
}

@(test)
evidence_bundle_directory_validator_rejects_tree_mutations_test :: proc(
	t: ^testing.T,
) {
	fixture: Directory_Test_Fixture
	testing.expect(t, directory_test_fixture_init(&fixture))
	defer directory_test_fixture_destroy(&fixture)
	root := directory_test_root(t)
	defer {
		os2.remove_all(root)
		delete(root)
	}
	for mutation in 0..<4 {
		name := fmt.aprintf("bundle-%d", mutation)
		destination := directory_test_join(t, {root, name})
		testing.expect_value(
			t,
			evidence_bundle_directory_publish(
				fixture.manifest,
				fixture.contents[:],
				destination,
			),
			Evidence_Bundle_Directory_Error.None,
		)
		primitive_path := directory_test_join(
			t,
			{destination, fixture.primitive.path},
		)
		switch mutation {
		case 0:
			unlisted := directory_test_join(t, {destination, ".DS_Store"})
			hidden_text := "hidden"
			testing.expect(
				t,
				os.write_entire_file(
					unlisted,
					transmute([]u8)hidden_text,
				),
			)
			delete(unlisted)
		case 1:
			changed_text := "changed"
			testing.expect(
				t,
				os.write_entire_file(
					primitive_path,
					transmute([]u8)changed_text,
				),
			)
		case 2:
			testing.expect(t, os.remove(primitive_path) == nil)
		case 3:
			testing.expect(t, os.remove(primitive_path) == nil)
			testing.expect(
				t,
				os2.symlink("/tmp", primitive_path) == nil,
			)
		}
		testing.expect(
			t,
			evidence_bundle_directory_validate(destination) != .None,
		)
		delete(primitive_path)
		delete(destination)
		delete(name)
	}
}

@(test)
evidence_bundle_directory_validator_verifies_manifest_descriptors_test :: proc(
	t: ^testing.T,
) {
	fixture: Directory_Test_Fixture
	testing.expect(t, directory_test_fixture_init(&fixture))
	defer directory_test_fixture_destroy(&fixture)
	root := directory_test_root(t)
	defer {
		os2.remove_all(root)
		delete(root)
	}
	descriptor_kinds := [2]bool{false, true}
	for stage_descriptor in descriptor_kinds {
		name := "summary-hash" if !stage_descriptor else "stage-hash"
		destination := directory_test_join(t, {root, name})
		testing.expect_value(
			t,
			evidence_bundle_directory_publish(
				fixture.manifest,
				fixture.contents[:],
				destination,
			),
			Evidence_Bundle_Directory_Error.None,
		)
		root_manifest_path :=
			directory_test_join(t, {destination, "manifest.json"})
		root_bytes, read_ok := os.read_entire_file(root_manifest_path)
		testing.expect(t, read_ok)
		decoded, decode_error := evidence_bundle_manifest_decode(root_bytes)
		delete(root_bytes)
		testing.expect_value(
			t,
			decode_error,
			Evidence_Bundle_Error.None,
		)
		hash := decoded.summary.sha256
		if stage_descriptor {hash = decoded.stages[0].manifest.sha256}
		hash_bytes := transmute([]u8)hash
		hash_bytes[0] = '0' if hash_bytes[0] != '0' else '1'
		changed_root_bytes, encode_error :=
			evidence_bundle_manifest_encode(decoded)
		evidence_bundle_manifest_destroy(&decoded)
		testing.expect_value(
			t,
			encode_error,
			Evidence_Bundle_Error.None,
		)
		testing.expect(
			t,
			os.write_entire_file(root_manifest_path, changed_root_bytes),
		)
		delete(changed_root_bytes)
		testing.expect_value(
			t,
			evidence_bundle_directory_validate(destination),
			Evidence_Bundle_Directory_Error.Invalid_Content,
		)
		delete(root_manifest_path)
		delete(destination)
	}
}

@(test)
evidence_bundle_directory_rejects_invalid_destinations_and_limits_test :: proc(
	t: ^testing.T,
) {
	fixture: Directory_Test_Fixture
	testing.expect(t, directory_test_fixture_init(&fixture))
	defer directory_test_fixture_destroy(&fixture)
	root := directory_test_root(t)
	defer {
		os2.remove_all(root)
		delete(root)
	}
	reserved := directory_test_join(
		t,
		{root, ".hw-slicer-staging-user"},
	)
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(
			fixture.manifest,
			fixture.contents[:],
			reserved,
		),
		Evidence_Bundle_Directory_Error.Invalid_Destination,
	)
	missing_parent := directory_test_join(
		t,
		{root, "missing", "bundle"},
	)
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(
			fixture.manifest,
			fixture.contents[:],
			missing_parent,
		),
		Evidence_Bundle_Directory_Error.Parent_Missing,
	)
	destination := directory_test_join(t, {root, "bundle"})
	limits := formats.DEFAULT_BOUNDED_ZIP_LIMITS
	limits.max_total_bytes = 1
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(
			fixture.manifest,
			fixture.contents[:],
			destination,
			limits = limits,
		),
		Evidence_Bundle_Directory_Error.Invalid_Manifest,
	)
	limits = formats.DEFAULT_BOUNDED_ZIP_LIMITS
	limits.max_path_bytes = 12
	testing.expect_value(
		t,
		evidence_bundle_directory_publish(
			fixture.manifest,
			fixture.contents[:],
			destination,
			limits = limits,
		),
		Evidence_Bundle_Directory_Error.Invalid_Manifest,
	)
	testing.expect(t, !directory_test_path_exists(destination))
	testing.expect_value(t, directory_test_staging_count(t, root), 0)
	delete(reserved)
	delete(missing_parent)
	delete(destination)
}
