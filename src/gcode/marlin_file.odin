package gcode

import "core:c"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"

import features "../features"
import profiles "../profiles"

MARLIN_FILE_STAGING_PREFIX :: ".hw-slicer-gcode-staging-"
MARLIN_FILE_RENAME_EXCL :: c.uint(0x00000004)

foreign import marlin_file_system "system:System"
foreign marlin_file_system {
	renameatx_np :: proc "c" (
		old_fd: c.int,
		old_path: cstring,
		new_fd: c.int,
		new_path: cstring,
		flags: c.uint,
	) -> c.int ---
}

Marlin_File_Error :: enum u8 {
	None,
	Invalid_Result,
	Invalid_Destination,
	Parent_Missing,
	Destination_Exists,
	Staging_Create_Failed,
	Write_Failed,
	Sync_Failed,
	Validation_Failed,
	Publish_Failed,
	Injected_Failure,
	Allocation_Failed,
	Cleanup_Failed,
}

Marlin_File_Test_Hook :: struct {
	fail_after_byte_count: u64,
	fail_before_rename:    bool,
}

marlin_file_publish :: proc(
	result: Marlin_Result,
	profile: profiles.Resolved_Profiles,
	motion: features.Motion_Plan_Result,
	destination: string,
	replace_existing := false,
	test_hook := Marlin_File_Test_Hook{},
	limits := DEFAULT_MARLIN_LIMITS,
	allocator := context.allocator,
) -> (publish_error: Marlin_File_Error) {
	_, valid_result :=
		marlin_result_hash({}, motion, profile, result, limits, allocator)
	if !valid_result {return .Invalid_Result}

	parent_path, destination_name, destination_error :=
		marlin_file_destination_split(destination, allocator)
	if destination_error != .None {return destination_error}
	defer delete(parent_path, allocator)
	parent_cstring :=
		strings.clone_to_cstring(parent_path, context.temp_allocator)
	parent_fd := posix.open(
		parent_cstring,
		{.DIRECTORY, .CLOEXEC, .NOFOLLOW},
	)
	if parent_fd < 0 {return .Parent_Missing}
	defer posix.close(parent_fd)
	destination_cstring :=
		strings.clone_to_cstring(destination_name, context.temp_allocator)
	destination_exists, destination_valid :=
		marlin_file_destination_state(parent_fd, destination_cstring)
	if !destination_valid {return .Invalid_Destination}
	if destination_exists && !replace_existing {
		return .Destination_Exists
	}

	staging_name_buffer: [128]u8
	staging_name := ""
	staging_fd := posix.FD(-1)
	nonce := u64(time.to_unix_nanoseconds(time.now()))
	for attempt in 0..<100 {
		staging_name = fmt.bprintf(
			staging_name_buffer[:],
			"%s%d-%016x-%02d",
			MARLIN_FILE_STAGING_PREFIX,
			posix.getpid(),
			nonce,
			attempt,
		)
		staging_cstring :=
			strings.clone_to_cstring(staging_name, context.temp_allocator)
		staging_fd = posix.openat(
			parent_fd,
			staging_cstring,
			{.WRONLY, .CREAT, .EXCL, .CLOEXEC, .NOFOLLOW},
			{.IRUSR, .IWUSR},
		)
		if staging_fd >= 0 {break}
		if posix.get_errno() != .EEXIST {
			return .Staging_Create_Failed
		}
	}
	if staging_fd < 0 {return .Staging_Create_Failed}
	staging_created := true
	published := false
	defer {
		if staging_fd >= 0 {
			posix.close(staging_fd)
		}
		if staging_created && !published {
			if !marlin_file_cleanup_at(parent_fd, staging_name) {
				publish_error = .Cleanup_Failed
			}
		}
	}
	if posix.fchmod(staging_fd, {.IRUSR, .IWUSR}) != .OK {
		return .Write_Failed
	}
	write_error := marlin_file_write_all(
		staging_fd,
		result.bytes,
		test_hook.fail_after_byte_count,
	)
	if write_error != .None {return write_error}
	if posix.fsync(staging_fd) != .OK {return .Sync_Failed}
	posix.close(staging_fd)
	staging_fd = -1

	validation_error := marlin_file_validate_staging(
		parent_fd,
		staging_name,
		result.bytes,
		profile,
		motion,
		allocator,
	)
	if validation_error != .None {return validation_error}
	if test_hook.fail_before_rename {return .Injected_Failure}

	destination_exists, destination_valid =
		marlin_file_destination_state(parent_fd, destination_cstring)
	if !destination_valid {return .Invalid_Destination}
	if destination_exists && !replace_existing {
		return .Destination_Exists
	}
	staging_cstring :=
		strings.clone_to_cstring(staging_name, context.temp_allocator)
	if replace_existing {
		if posix.renameat(
			parent_fd,
			staging_cstring,
			parent_fd,
			destination_cstring,
		) != .OK {
			return .Publish_Failed
		}
	} else if renameatx_np(
		c.int(parent_fd),
		staging_cstring,
		c.int(parent_fd),
		destination_cstring,
		MARLIN_FILE_RENAME_EXCL,
	) != 0 {
		if posix.get_errno() == .EEXIST {return .Destination_Exists}
		return .Publish_Failed
	}
	published = true
	staging_created = false
	if posix.fsync(parent_fd) != .OK {return .Sync_Failed}
	return .None
}

marlin_file_destination_split :: proc(
	destination: string,
	allocator := context.allocator,
) -> (
	parent_path, destination_name: string,
	publish_error: Marlin_File_Error,
) {
	if destination == "" ||
	   destination[len(destination)-1] == '/' ||
	   strings.contains(destination, "\x00") {
		return "", "", .Invalid_Destination
	}
	parent, name := filepath.split(destination)
	if name == "" ||
	   name == "." ||
	   name == ".." ||
	   len(name) > 255 ||
	   !strings.has_suffix(name, ".gcode") ||
	   strings.has_prefix(name, MARLIN_FILE_STAGING_PREFIX) {
		return "", "", .Invalid_Destination
	}
	if parent == "" {parent = "."}
	absolute_parent, absolute_ok := filepath.abs(parent, allocator)
	if !absolute_ok || absolute_parent == "" {
		return "", "", .Parent_Missing
	}
	return absolute_parent, name, .None
}

marlin_file_destination_state :: proc(
	parent_fd: posix.FD,
	name: cstring,
) -> (exists, valid: bool) {
	status: posix.stat_t
	if posix.fstatat(
		parent_fd,
		name,
		&status,
		{.SYMLINK_NOFOLLOW},
	) == .OK {
		return true, posix.S_ISREG(status.st_mode)
	}
	if posix.get_errno() == .ENOENT {return false, true}
	return false, false
}

marlin_file_write_all :: proc(
	file_fd: posix.FD,
	bytes: []u8,
	fail_after_byte_count: u64,
) -> Marlin_File_Error {
	offset: int
	for offset < len(bytes) {
		write_count := len(bytes)-offset
		if fail_after_byte_count > u64(offset) &&
		   fail_after_byte_count-u64(offset) < u64(write_count) {
			write_count = int(fail_after_byte_count-u64(offset))
		}
		written := posix.write(
			file_fd,
			raw_data(bytes[offset:]),
			c.size_t(write_count),
		)
		if written <= 0 {return .Write_Failed}
		offset += int(written)
		if fail_after_byte_count > 0 &&
		   u64(offset) >= fail_after_byte_count {
			return .Injected_Failure
		}
	}
	return .None
}

marlin_file_validate_staging :: proc(
	parent_fd: posix.FD,
	staging_name: string,
	expected_bytes: []u8,
	profile: profiles.Resolved_Profiles,
	motion: features.Motion_Plan_Result,
	allocator := context.allocator,
) -> Marlin_File_Error {
	staging_cstring :=
		strings.clone_to_cstring(staging_name, context.temp_allocator)
	file_fd := posix.openat(
		parent_fd,
		staging_cstring,
		{.CLOEXEC, .NOFOLLOW},
	)
	if file_fd < 0 {return .Validation_Failed}
	defer posix.close(file_fd)
	status: posix.stat_t
	if posix.fstat(file_fd, &status) != .OK ||
	   !posix.S_ISREG(status.st_mode) ||
	   status.st_size < 0 ||
	   u64(status.st_size) != u64(len(expected_bytes)) {
		return .Validation_Failed
	}
	bytes := make([]u8, len(expected_bytes), allocator)
	if len(expected_bytes) > 0 && bytes == nil {
		return .Allocation_Failed
	}
	defer delete(bytes, allocator)
	offset: int
	for offset < len(bytes) {
		remaining := len(bytes)-offset
		read_count := posix.read(
			file_fd,
			raw_data(bytes[offset:]),
			c.size_t(remaining),
		)
		if read_count <= 0 {return .Validation_Failed}
		offset += int(read_count)
	}
	extra: [1]u8
	if posix.read(file_fd, raw_data(extra[:]), 1) != 0 {
		return .Validation_Failed
	}
	for byte, byte_index in bytes {
		if byte != expected_bytes[byte_index] {
			return .Validation_Failed
		}
	}
	_, validation_error := marlin_validate(bytes, profile, motion)
	if validation_error != .None {return .Validation_Failed}
	return .None
}

marlin_file_cleanup_at :: proc(
	parent_fd: posix.FD,
	staging_name: string,
) -> bool {
	if !strings.has_prefix(staging_name, MARLIN_FILE_STAGING_PREFIX) {
		return false
	}
	staging_cstring :=
		strings.clone_to_cstring(staging_name, context.temp_allocator)
	if posix.unlinkat(parent_fd, staging_cstring, {}) == .OK {
		return true
	}
	return posix.get_errno() == .ENOENT
}
