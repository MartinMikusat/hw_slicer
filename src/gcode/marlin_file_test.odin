package gcode

import "core:os"
import "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import features "../features"

@(test)
marlin_file_publishes_valid_bytes_without_staging_residue_test :: proc(
	t: ^testing.T,
) {
	profile := marlin_test_profile(t)
	motion := marlin_test_motion()
	defer features.motion_plan_result_destroy(&motion)
	result, emit_error := marlin_emit(motion, profile)
	defer marlin_result_destroy(&result)
	testing.expect_value(t, emit_error, Marlin_Error.None)
	root := marlin_file_test_root(t)
	defer {
		os2.remove_all(root)
		delete(root)
	}
	destination := marlin_file_test_join(t, {root, "part.gcode"})
	defer delete(destination)
	publish_error :=
		marlin_file_publish(result, profile, motion, destination)
	testing.expect_value(t, publish_error, Marlin_File_Error.None)
	actual, read_ok := os.read_entire_file(destination)
	defer delete(actual)
	testing.expect(t, read_ok)
	testing.expect(t, marlin_test_bytes_equal(actual, result.bytes))
	_, validation_error := marlin_validate(actual, profile, motion)
	testing.expect_value(
		t,
		validation_error,
		Marlin_Validation_Error.None,
	)
	testing.expect_value(t, marlin_file_test_staging_count(t, root), 0)
}

@(test)
marlin_file_create_only_preserves_existing_file_test :: proc(
	t: ^testing.T,
) {
	profile := marlin_test_profile(t)
	motion := marlin_test_motion()
	defer features.motion_plan_result_destroy(&motion)
	result, emit_error := marlin_emit(motion, profile)
	defer marlin_result_destroy(&result)
	testing.expect_value(t, emit_error, Marlin_Error.None)
	root := marlin_file_test_root(t)
	defer {
		os2.remove_all(root)
		delete(root)
	}
	destination := marlin_file_test_join(t, {root, "part.gcode"})
	defer delete(destination)
	marker_text := "existing\n"
	marker := transmute([]u8)marker_text
	testing.expect(t, os.write_entire_file(destination, marker))
	publish_error :=
		marlin_file_publish(result, profile, motion, destination)
	testing.expect_value(
		t,
		publish_error,
		Marlin_File_Error.Destination_Exists,
	)
	actual, read_ok := os.read_entire_file(destination)
	defer delete(actual)
	testing.expect(t, read_ok)
	testing.expect(t, marlin_test_bytes_equal(actual, marker))
	testing.expect_value(t, marlin_file_test_staging_count(t, root), 0)
}

@(test)
marlin_file_injected_partial_write_preserves_existing_file_test :: proc(
	t: ^testing.T,
) {
	profile := marlin_test_profile(t)
	motion := marlin_test_motion()
	defer features.motion_plan_result_destroy(&motion)
	result, emit_error := marlin_emit(motion, profile)
	defer marlin_result_destroy(&result)
	testing.expect_value(t, emit_error, Marlin_Error.None)
	root := marlin_file_test_root(t)
	defer {
		os2.remove_all(root)
		delete(root)
	}
	destination := marlin_file_test_join(t, {root, "part.gcode"})
	defer delete(destination)
	marker_text := "existing\n"
	marker := transmute([]u8)marker_text
	testing.expect(t, os.write_entire_file(destination, marker))
	publish_error := marlin_file_publish(
		result,
		profile,
		motion,
		destination,
		true,
		{fail_after_byte_count = 17},
	)
	testing.expect_value(
		t,
		publish_error,
		Marlin_File_Error.Injected_Failure,
	)
	actual, read_ok := os.read_entire_file(destination)
	defer delete(actual)
	testing.expect(t, read_ok)
	testing.expect(t, marlin_test_bytes_equal(actual, marker))
	testing.expect_value(t, marlin_file_test_staging_count(t, root), 0)
}

@(test)
marlin_file_injected_pre_publish_failure_preserves_existing_file_test :: proc(
	t: ^testing.T,
) {
	profile := marlin_test_profile(t)
	motion := marlin_test_motion()
	defer features.motion_plan_result_destroy(&motion)
	result, emit_error := marlin_emit(motion, profile)
	defer marlin_result_destroy(&result)
	testing.expect_value(t, emit_error, Marlin_Error.None)
	root := marlin_file_test_root(t)
	defer {
		os2.remove_all(root)
		delete(root)
	}
	destination := marlin_file_test_join(t, {root, "part.gcode"})
	defer delete(destination)
	marker_text := "existing\n"
	marker := transmute([]u8)marker_text
	testing.expect(t, os.write_entire_file(destination, marker))
	publish_error := marlin_file_publish(
		result,
		profile,
		motion,
		destination,
		true,
		{fail_before_rename = true},
	)
	testing.expect_value(
		t,
		publish_error,
		Marlin_File_Error.Injected_Failure,
	)
	actual, read_ok := os.read_entire_file(destination)
	defer delete(actual)
	testing.expect(t, read_ok)
	testing.expect(t, marlin_test_bytes_equal(actual, marker))
	testing.expect_value(t, marlin_file_test_staging_count(t, root), 0)
}

@(test)
marlin_file_explicit_replace_publishes_valid_file_test :: proc(
	t: ^testing.T,
) {
	profile := marlin_test_profile(t)
	motion := marlin_test_motion()
	defer features.motion_plan_result_destroy(&motion)
	result, emit_error := marlin_emit(motion, profile)
	defer marlin_result_destroy(&result)
	testing.expect_value(t, emit_error, Marlin_Error.None)
	root := marlin_file_test_root(t)
	defer {
		os2.remove_all(root)
		delete(root)
	}
	destination := marlin_file_test_join(t, {root, "part.gcode"})
	defer delete(destination)
	marker_text := "existing\n"
	testing.expect(
		t,
		os.write_entire_file(destination, transmute([]u8)marker_text),
	)
	publish_error :=
		marlin_file_publish(result, profile, motion, destination, true)
	testing.expect_value(t, publish_error, Marlin_File_Error.None)
	actual, read_ok := os.read_entire_file(destination)
	defer delete(actual)
	testing.expect(t, read_ok)
	testing.expect(t, marlin_test_bytes_equal(actual, result.bytes))
	testing.expect_value(t, marlin_file_test_staging_count(t, root), 0)
}

@(test)
marlin_file_rejects_invalid_result_before_staging_test :: proc(
	t: ^testing.T,
) {
	profile := marlin_test_profile(t)
	motion := marlin_test_motion()
	defer features.motion_plan_result_destroy(&motion)
	result, emit_error := marlin_emit(motion, profile)
	defer marlin_result_destroy(&result)
	testing.expect_value(t, emit_error, Marlin_Error.None)
	result.bytes[0] = 'X'
	root := marlin_file_test_root(t)
	defer {
		os2.remove_all(root)
		delete(root)
	}
	destination := marlin_file_test_join(t, {root, "part.gcode"})
	defer delete(destination)
	publish_error :=
		marlin_file_publish(result, profile, motion, destination)
	testing.expect_value(
		t,
		publish_error,
		Marlin_File_Error.Invalid_Result,
	)
	testing.expect(t, !marlin_file_test_path_exists(destination))
	testing.expect_value(t, marlin_file_test_staging_count(t, root), 0)
}

@(test)
marlin_file_rejects_symlink_destination_without_touching_target_test :: proc(
	t: ^testing.T,
) {
	profile := marlin_test_profile(t)
	motion := marlin_test_motion()
	defer features.motion_plan_result_destroy(&motion)
	result, emit_error := marlin_emit(motion, profile)
	defer marlin_result_destroy(&result)
	testing.expect_value(t, emit_error, Marlin_Error.None)
	root := marlin_file_test_root(t)
	defer {
		os2.remove_all(root)
		delete(root)
	}
	target := marlin_file_test_join(t, {root, "target.txt"})
	defer delete(target)
	destination := marlin_file_test_join(t, {root, "part.gcode"})
	defer delete(destination)
	marker_text := "target\n"
	marker := transmute([]u8)marker_text
	testing.expect(t, os.write_entire_file(target, marker))
	testing.expect(t, os2.symlink(target, destination) == nil)
	publish_error :=
		marlin_file_publish(result, profile, motion, destination, true)
	testing.expect_value(
		t,
		publish_error,
		Marlin_File_Error.Invalid_Destination,
	)
	actual, read_ok := os.read_entire_file(target)
	defer delete(actual)
	testing.expect(t, read_ok)
	testing.expect(t, marlin_test_bytes_equal(actual, marker))
	testing.expect_value(t, marlin_file_test_staging_count(t, root), 0)
}

marlin_file_test_root :: proc(t: ^testing.T) -> string {
	path, error := os2.make_directory_temp(
		"/tmp",
		"hw-slicer-gcode-*",
		context.allocator,
	)
	testing.expect(t, error == nil)
	return path
}

marlin_file_test_join :: proc(t: ^testing.T, parts: []string) -> string {
	path, error := filepath.join(parts)
	testing.expect(t, error == nil)
	return path
}

marlin_file_test_path_exists :: proc(path: string) -> bool {
	info, error := os.lstat(path)
	if error != nil {return false}
	os.file_info_delete(info)
	return true
}

marlin_file_test_staging_count :: proc(
	t: ^testing.T,
	path: string,
) -> int {
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
		if strings.has_prefix(info.name, MARLIN_FILE_STAGING_PREFIX) {
			count += 1
		}
	}
	return count
}
