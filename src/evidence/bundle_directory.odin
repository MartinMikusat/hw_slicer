package evidence

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"

import formats "../formats"

EVIDENCE_BUNDLE_STAGING_PREFIX :: ".hw-slicer-staging-"
EVIDENCE_BUNDLE_DIRECTORY_RENAME_EXCL :: c.uint(0x00000004)

foreign import evidence_bundle_directory_system "system:System"
foreign evidence_bundle_directory_system {
	renameatx_np :: proc "c" (
		old_fd: c.int,
		old_path: cstring,
		new_fd: c.int,
		new_path: cstring,
		flags: c.uint,
	) -> c.int ---
}

Evidence_Bundle_Directory_Error :: enum u8 {
	None,
	Invalid_Manifest,
	Invalid_Content,
	Missing_Content,
	Invalid_Destination,
	Parent_Missing,
	Destination_Exists,
	Staging_Create_Failed,
	Directory_Create_Failed,
	File_Write_Failed,
	Sync_Failed,
	Validation_Failed,
	Publish_Failed,
	Injected_Failure,
	Allocation_Failed,
	Cleanup_Failed,
}

Evidence_Bundle_Directory_Test_Hook :: struct {
	fail_after_file_count: u64,
	fail_before_rename:    bool,
}

evidence_bundle_directory_publish :: proc(
	manifest: Evidence_Bundle_Manifest,
	contents: []Evidence_Bundle_Content,
	destination: string,
	test_hook := Evidence_Bundle_Directory_Test_Hook{},
	limits := formats.DEFAULT_BOUNDED_ZIP_LIMITS,
	allocator := context.allocator,
) -> (result: Evidence_Bundle_Directory_Error) {
	content_error :=
		evidence_bundle_contents_validate(manifest, contents, allocator)
	switch content_error {
	case .None:
	case .Invalid_Manifest:
		return .Invalid_Manifest
	case .Missing_Content:
		return .Missing_Content
	case .Allocation_Failed:
		return .Allocation_Failed
	case .Invalid_Content,
	     .Duplicate_Content,
	     .Manifest_Encode_Failed,
	     .Zip_Write_Failed,
	     .Zip_Read_Failed:
		return .Invalid_Content
	}
	root_manifest_bytes, manifest_error :=
		evidence_bundle_manifest_encode(manifest, allocator)
	if manifest_error != .None {
		if manifest_error == .Encode_Failed {
			return .Allocation_Failed
		}
		return .Invalid_Manifest
	}
	defer delete(root_manifest_bytes, allocator)
	if !evidence_bundle_directory_manifest_fits_limits(
		manifest,
		u64(len(root_manifest_bytes)),
		limits,
	) {
		return .Invalid_Manifest
	}

	parent_path, destination_name, destination_error :=
		evidence_bundle_directory_destination_split(destination, allocator)
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
	destination_status: posix.stat_t
	if posix.fstatat(
		parent_fd,
		destination_cstring,
		&destination_status,
		{.SYMLINK_NOFOLLOW},
	) == .OK {
		return .Destination_Exists
	}
	if posix.get_errno() != .ENOENT {return .Invalid_Destination}

	staging_name_buffer: [128]u8
	staging_name := ""
	staging_fd := posix.FD(-1)
	nonce := u64(time.to_unix_nanoseconds(time.now()))
	for attempt in 0..<100 {
		staging_name = fmt.bprintf(
			staging_name_buffer[:],
			"%s%d-%016x-%02d",
			EVIDENCE_BUNDLE_STAGING_PREFIX,
			posix.getpid(),
			nonce,
			attempt,
		)
		staging_cstring :=
			strings.clone_to_cstring(staging_name, context.temp_allocator)
		if posix.mkdirat(
			parent_fd,
			staging_cstring,
			{.IRUSR, .IWUSR, .IXUSR},
		) == .OK {
			staging_fd = posix.openat(
				parent_fd,
				staging_cstring,
				{.DIRECTORY, .CLOEXEC, .NOFOLLOW},
			)
			break
		}
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
			if !evidence_bundle_directory_cleanup_at(
				parent_fd,
				staging_name,
				allocator,
			) {
				result = .Cleanup_Failed
			}
		}
	}

	files_written: u64
	for file in manifest.files {
		content, found := evidence_bundle_content_find(contents, file.path)
		if !found {return .Missing_Content}
		write_error := evidence_bundle_directory_write_file(
			staging_fd,
			file.path,
			content.bytes,
		)
		if write_error != .None {return write_error}
		files_written += 1
		if test_hook.fail_after_file_count == files_written {
			return .Injected_Failure
		}
	}
	summary_content, summary_found :=
		evidence_bundle_content_find(contents, manifest.summary.path)
	if !summary_found {return .Missing_Content}
	write_error := evidence_bundle_directory_write_file(
		staging_fd,
		manifest.summary.path,
		summary_content.bytes,
	)
	if write_error != .None {return write_error}
	files_written += 1
	if test_hook.fail_after_file_count == files_written {
		return .Injected_Failure
	}
	for stage in manifest.stages {
		content, found :=
			evidence_bundle_content_find(contents, stage.manifest.path)
		if !found {return .Missing_Content}
		write_error = evidence_bundle_directory_write_file(
			staging_fd,
			stage.manifest.path,
			content.bytes,
		)
		if write_error != .None {return write_error}
		files_written += 1
		if test_hook.fail_after_file_count == files_written {
			return .Injected_Failure
		}
	}
	write_error = evidence_bundle_directory_write_file(
		staging_fd,
		"manifest.json",
		root_manifest_bytes,
	)
	if write_error != .None {return write_error}
	files_written += 1
	if test_hook.fail_after_file_count == files_written {
		return .Injected_Failure
	}
	if !evidence_bundle_directory_sync_tree(staging_fd, allocator) {
		return .Sync_Failed
	}
	posix.close(staging_fd)
	staging_fd = -1

	staging_path, staging_path_error := filepath.join(
		{parent_path, staging_name},
		allocator,
	)
	if staging_path_error != nil {return .Allocation_Failed}
	defer delete(staging_path, allocator)
	validation_error := evidence_bundle_directory_validate(
		staging_path,
		limits,
		allocator,
	)
	if validation_error != .None {
		return .Validation_Failed
	}
	if test_hook.fail_before_rename {return .Injected_Failure}
	if posix.fstatat(
		parent_fd,
		destination_cstring,
		&destination_status,
		{.SYMLINK_NOFOLLOW},
	) == .OK {
		return .Destination_Exists
	}
	if posix.get_errno() != .ENOENT {return .Publish_Failed}
	staging_cstring :=
		strings.clone_to_cstring(staging_name, context.temp_allocator)
	if renameatx_np(
		c.int(parent_fd),
		staging_cstring,
		c.int(parent_fd),
		destination_cstring,
		EVIDENCE_BUNDLE_DIRECTORY_RENAME_EXCL,
	) != 0 {
		if posix.get_errno() == .EEXIST {return .Destination_Exists}
		return .Publish_Failed
	}
	published = true
	staging_created = false
	if posix.fsync(parent_fd) != .OK {return .Sync_Failed}
	return .None
}

evidence_bundle_directory_validate :: proc(
	root_path: string,
	limits := formats.DEFAULT_BOUNDED_ZIP_LIMITS,
	allocator := context.allocator,
) -> Evidence_Bundle_Directory_Error {
	replay, error :=
		evidence_bundle_directory_replay(root_path, limits, allocator)
	evidence_bundle_replay_destroy(&replay, allocator)
	return error
}

evidence_bundle_directory_destination_split :: proc(
	destination: string,
	allocator := context.allocator,
) -> (
	parent_path, destination_name: string,
	error: Evidence_Bundle_Directory_Error,
) {
	if destination == "" ||
	   destination[len(destination)-1] == '/' ||
	   strings.has_prefix(
	   	filepath.base(destination),
	   	EVIDENCE_BUNDLE_STAGING_PREFIX,
	   ) {
		return "", "", .Invalid_Destination
	}
	parent, name := filepath.split(destination)
	if name == "" || name == "." || name == ".." || len(name) > 255 {
		return "", "", .Invalid_Destination
	}
	if parent == "" {parent = "."}
	absolute_parent, absolute_ok := filepath.abs(parent, allocator)
	if !absolute_ok || absolute_parent == "" {
		return "", "", .Parent_Missing
	}
	return absolute_parent, name, .None
}

evidence_bundle_directory_manifest_fits_limits :: proc(
	manifest: Evidence_Bundle_Manifest,
	root_manifest_byte_count: u64,
	limits: formats.Bounded_Zip_Limits,
) -> bool {
	entry_count := u64(2+len(manifest.stages)+len(manifest.files))
	if entry_count > u64(limits.max_entries) {return false}
	if root_manifest_byte_count > limits.max_entry_bytes ||
	   root_manifest_byte_count > limits.max_total_bytes ||
	   u32(len("manifest.json")) > limits.max_path_bytes ||
	   manifest.summary.byte_count > limits.max_entry_bytes ||
	   manifest.summary.byte_count >
	   	limits.max_total_bytes-root_manifest_byte_count ||
	   u32(len(manifest.summary.path)) > limits.max_path_bytes {
		return false
	}
	total_bytes := root_manifest_byte_count+manifest.summary.byte_count
	for stage in manifest.stages {
		if stage.manifest.byte_count > limits.max_entry_bytes ||
		   stage.manifest.byte_count > limits.max_total_bytes ||
		   u32(len(stage.manifest.path)) > limits.max_path_bytes ||
		   total_bytes > limits.max_total_bytes-stage.manifest.byte_count {
			return false
		}
		total_bytes += stage.manifest.byte_count
	}
	for file in manifest.files {
		if file.byte_count > limits.max_entry_bytes ||
		   file.byte_count > limits.max_total_bytes ||
		   u32(len(file.path)) > limits.max_path_bytes ||
		   total_bytes > limits.max_total_bytes-file.byte_count {
			return false
		}
		total_bytes += file.byte_count
	}
	return total_bytes <= limits.max_total_bytes
}

evidence_bundle_directory_write_file :: proc(
	root_fd: posix.FD,
	path: string,
	bytes: []u8,
) -> Evidence_Bundle_Directory_Error {
	parent_fd, name, parent_error :=
		evidence_bundle_directory_open_parent(root_fd, path, true)
	if parent_error != .None {return parent_error}
	defer {
		if parent_fd != root_fd {posix.close(parent_fd)}
	}
	name_cstring :=
		strings.clone_to_cstring(name, context.temp_allocator)
	file_fd := posix.openat(
		parent_fd,
		name_cstring,
		{.WRONLY, .CREAT, .EXCL, .CLOEXEC, .NOFOLLOW},
		{.IRUSR, .IWUSR},
	)
	if file_fd < 0 {return .File_Write_Failed}
	defer posix.close(file_fd)
	if posix.fchmod(file_fd, {.IRUSR, .IWUSR}) != .OK {
		return .File_Write_Failed
	}
	offset: int
	for offset < len(bytes) {
		remaining := len(bytes)-offset
		written := posix.write(
			file_fd,
			raw_data(bytes[offset:]),
			c.size_t(remaining),
		)
		if written <= 0 {return .File_Write_Failed}
		offset += int(written)
	}
	if posix.fsync(file_fd) != .OK {return .Sync_Failed}
	return .None
}

evidence_bundle_directory_read_file :: proc(
	root_fd: posix.FD,
	path: string,
	minimum_byte_count, maximum_byte_count: u64,
	allocator := context.allocator,
) -> ([]u8, Evidence_Bundle_Directory_Error) {
	if !artifact_path_valid(path) ||
	   minimum_byte_count > maximum_byte_count ||
	   maximum_byte_count > u64(max(int)) {
		return nil, .Invalid_Content
	}
	parent_fd, name, parent_error :=
		evidence_bundle_directory_open_parent(root_fd, path, false)
	if parent_error != .None {
		if parent_error == .Allocation_Failed {
			return nil, .Allocation_Failed
		}
		return nil, .Missing_Content
	}
	defer {
		if parent_fd != root_fd {posix.close(parent_fd)}
	}
	name_cstring :=
		strings.clone_to_cstring(name, context.temp_allocator)
	file_fd := posix.openat(
		parent_fd,
		name_cstring,
		{.CLOEXEC, .NOFOLLOW},
	)
	if file_fd < 0 {return nil, .Missing_Content}
	defer posix.close(file_fd)
	status: posix.stat_t
	if posix.fstat(file_fd, &status) != .OK ||
	   !posix.S_ISREG(status.st_mode) ||
	   status.st_size < 0 {
		return nil, .Invalid_Content
	}
	byte_count := u64(status.st_size)
	if byte_count < minimum_byte_count ||
	   byte_count > maximum_byte_count {
		return nil, .Invalid_Content
	}
	bytes := make([]u8, int(byte_count), allocator)
	if byte_count > 0 && bytes == nil {return nil, .Allocation_Failed}
	offset: int
	for offset < len(bytes) {
		remaining := len(bytes)-offset
		read_count := posix.read(
			file_fd,
			raw_data(bytes[offset:]),
			c.size_t(remaining),
		)
		if read_count <= 0 {
			delete(bytes, allocator)
			return nil, .Invalid_Content
		}
		offset += int(read_count)
	}
	extra: [1]u8
	extra_count := posix.read(file_fd, raw_data(extra[:]), 1)
	if extra_count != 0 {
		delete(bytes, allocator)
		return nil, .Invalid_Content
	}
	return bytes, .None
}

evidence_bundle_directory_open_parent :: proc(
	root_fd: posix.FD,
	path: string,
	create: bool,
) -> (
	parent_fd: posix.FD,
	name: string,
	error: Evidence_Bundle_Directory_Error,
) {
	if !artifact_path_valid(path) {
		return -1, "", .Invalid_Content
	}
	current_fd := root_fd
	owns_current := false
	segment_start := 0
	for byte, byte_index in transmute([]u8)path {
		if byte != '/' {continue}
		segment := path[segment_start:byte_index]
		segment_cstring :=
			strings.clone_to_cstring(segment, context.temp_allocator)
		if create {
			mkdir_result := posix.mkdirat(
				current_fd,
				segment_cstring,
				{.IRUSR, .IWUSR, .IXUSR},
			)
			if mkdir_result != .OK && posix.get_errno() != .EEXIST {
				if owns_current {posix.close(current_fd)}
				return -1, "", .Directory_Create_Failed
			}
		}
		next_fd := posix.openat(
			current_fd,
			segment_cstring,
			{.DIRECTORY, .CLOEXEC, .NOFOLLOW},
		)
		if next_fd < 0 {
			if owns_current {posix.close(current_fd)}
			if create {
				return -1, "", .Directory_Create_Failed
			}
			return -1, "", .Missing_Content
		}
		if owns_current {posix.close(current_fd)}
		current_fd = next_fd
		owns_current = true
		segment_start = byte_index+1
	}
	return current_fd, path[segment_start:], .None
}

evidence_bundle_directory_walk_validate :: proc(
	directory_fd: posix.FD,
	prefix: string,
	manifest: Evidence_Bundle_Manifest,
	node_count: ^u64,
	node_limit: u64,
	max_path_bytes: u32,
	allocator := context.allocator,
) -> Evidence_Bundle_Directory_Error {
	infos, read_error :=
		os.read_dir(transmute(os.Handle)directory_fd, -1, allocator)
	if read_error != nil {return .Invalid_Content}
	defer os.file_info_slice_delete(infos, allocator)
	for info in infos {
		node_count^ += 1
		if node_count^ > node_limit ||
		   info.name == "" ||
		   strings.contains(info.name, "/") {
			return .Invalid_Content
		}
		relative_path := ""
		if prefix == "" {
			relative_path = strings.clone(info.name, allocator)
		} else {
			relative_path = fmt.aprintf(
				"%s/%s",
				prefix,
				info.name,
				allocator = allocator,
			)
		}
		if relative_path == "" {return .Allocation_Failed}
		path_too_long :=
			len(relative_path) > int(max_path_bytes)
		if path_too_long {
			delete(relative_path, allocator)
			return .Invalid_Content
		}
		name_cstring :=
			strings.clone_to_cstring(info.name, context.temp_allocator)
		status: posix.stat_t
		if posix.fstatat(
			directory_fd,
			name_cstring,
			&status,
			{.SYMLINK_NOFOLLOW},
		) != .OK {
			delete(relative_path, allocator)
			return .Invalid_Content
		}
		if posix.S_ISDIR(status.st_mode) {
			if !evidence_bundle_directory_expected_path(
				manifest,
				relative_path,
				true,
			) {
				delete(relative_path, allocator)
				return .Invalid_Content
			}
			child_fd := posix.openat(
				directory_fd,
				name_cstring,
				{.DIRECTORY, .CLOEXEC, .NOFOLLOW},
			)
			if child_fd < 0 {
				delete(relative_path, allocator)
				return .Invalid_Content
			}
			child_error := evidence_bundle_directory_walk_validate(
				child_fd,
				relative_path,
				manifest,
				node_count,
				node_limit,
				max_path_bytes,
				allocator,
			)
			posix.close(child_fd)
			delete(relative_path, allocator)
			if child_error != .None {return child_error}
		} else if posix.S_ISREG(status.st_mode) {
			expected := evidence_bundle_directory_expected_path(
				manifest,
				relative_path,
				false,
			)
			delete(relative_path, allocator)
			if !expected {return .Invalid_Content}
		} else {
			delete(relative_path, allocator)
			return .Invalid_Content
		}
	}
	return .None
}

evidence_bundle_directory_expected_node_limit :: proc(
	manifest: Evidence_Bundle_Manifest,
) -> u64 {
	limit := u64(2+len(manifest.stages)+len(manifest.files))
	limit += evidence_bundle_directory_slash_count(manifest.summary.path)
	for stage in manifest.stages {
		limit += evidence_bundle_directory_slash_count(stage.manifest.path)
	}
	for file in manifest.files {
		limit += evidence_bundle_directory_slash_count(file.path)
	}
	return limit
}

evidence_bundle_directory_slash_count :: proc(path: string) -> u64 {
	count: u64
	for byte in transmute([]u8)path {
		if byte == '/' {count += 1}
	}
	return count
}

evidence_bundle_directory_expected_path :: proc(
	manifest: Evidence_Bundle_Manifest,
	path: string,
	directory: bool,
) -> bool {
	if !directory {
		if path == "manifest.json" {return true}
		_, found := evidence_bundle_descriptor_find(manifest, path)
		return found
	}
	if evidence_bundle_directory_path_has_parent(
		manifest.summary.path,
		path,
	) {
		return true
	}
	for stage in manifest.stages {
		if evidence_bundle_directory_path_has_parent(
			stage.manifest.path,
			path,
		) {
			return true
		}
	}
	for file in manifest.files {
		if evidence_bundle_directory_path_has_parent(file.path, path) {
			return true
		}
	}
	return false
}

evidence_bundle_directory_path_has_parent :: proc(
	expected, parent: string,
) -> bool {
	return len(expected) > len(parent) &&
		expected[:len(parent)] == parent &&
		expected[len(parent)] == '/'
}

evidence_bundle_directory_sync_tree :: proc(
	directory_fd: posix.FD,
	allocator := context.allocator,
) -> bool {
	infos, read_error :=
		os.read_dir(transmute(os.Handle)directory_fd, -1, allocator)
	if read_error != nil {return false}
	defer os.file_info_slice_delete(infos, allocator)
	for info in infos {
		if !info.is_dir {continue}
		name_cstring :=
			strings.clone_to_cstring(info.name, context.temp_allocator)
		child_fd := posix.openat(
			directory_fd,
			name_cstring,
			{.DIRECTORY, .CLOEXEC, .NOFOLLOW},
		)
		if child_fd < 0 {return false}
		child_ok := evidence_bundle_directory_sync_tree(child_fd, allocator)
		posix.close(child_fd)
		if !child_ok {return false}
	}
	return posix.fsync(directory_fd) == .OK
}

evidence_bundle_directory_cleanup_at :: proc(
	parent_fd: posix.FD,
	name: string,
	allocator := context.allocator,
) -> bool {
	if !strings.has_prefix(name, EVIDENCE_BUNDLE_STAGING_PREFIX) {
		return false
	}
	name_cstring :=
		strings.clone_to_cstring(name, context.temp_allocator)
	directory_fd := posix.openat(
		parent_fd,
		name_cstring,
		{.DIRECTORY, .CLOEXEC, .NOFOLLOW},
	)
	if directory_fd < 0 {
		return posix.get_errno() == .ENOENT
	}
	clean := evidence_bundle_directory_remove_children(
		directory_fd,
		allocator,
	)
	posix.close(directory_fd)
	if !clean {return false}
	return posix.unlinkat(parent_fd, name_cstring, {.REMOVEDIR}) == .OK
}

evidence_bundle_directory_remove_children :: proc(
	directory_fd: posix.FD,
	allocator := context.allocator,
) -> bool {
	infos, read_error :=
		os.read_dir(transmute(os.Handle)directory_fd, -1, allocator)
	if read_error != nil {return false}
	defer os.file_info_slice_delete(infos, allocator)
	for info in infos {
		name_cstring :=
			strings.clone_to_cstring(info.name, context.temp_allocator)
		status: posix.stat_t
		if posix.fstatat(
			directory_fd,
			name_cstring,
			&status,
			{.SYMLINK_NOFOLLOW},
		) != .OK {
			return false
		}
		if posix.S_ISDIR(status.st_mode) {
			child_fd := posix.openat(
				directory_fd,
				name_cstring,
				{.DIRECTORY, .CLOEXEC, .NOFOLLOW},
			)
			if child_fd < 0 {return false}
			child_clean := evidence_bundle_directory_remove_children(
				child_fd,
				allocator,
			)
			posix.close(child_fd)
			if !child_clean ||
			   posix.unlinkat(
			   	directory_fd,
			   	name_cstring,
			   	{.REMOVEDIR},
			   ) != .OK {
				return false
			}
		} else if posix.unlinkat(directory_fd, name_cstring, {}) != .OK {
			return false
		}
	}
	return true
}

evidence_bundle_bytes_equal :: proc(left, right: []u8) -> bool {
	if len(left) != len(right) {return false}
	for byte, byte_index in left {
		if byte != right[byte_index] {return false}
	}
	return true
}
