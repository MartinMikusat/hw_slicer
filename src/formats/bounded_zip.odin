package formats

import "core:bytes"
import "core:compress/zlib"
import "core:strings"
import "core:unicode/utf8"

ZIP_LOCAL_HEADER_SIGNATURE :: u32(0x04034b50)
ZIP_CENTRAL_HEADER_SIGNATURE :: u32(0x02014b50)
ZIP_END_SIGNATURE :: u32(0x06054b50)
ZIP_DATA_DESCRIPTOR_SIGNATURE :: u32(0x08074b50)
ZIP_MAX_COMMENT_BYTES :: 65_535

Bounded_Zip_Limits :: struct {
	max_source_bytes:       u64,
	max_entries:            u32,
	max_path_bytes:         u32,
	max_entry_bytes:        u64,
	max_total_bytes:        u64,
	max_compression_ratio:  u32,
}

DEFAULT_BOUNDED_ZIP_LIMITS :: Bounded_Zip_Limits{
	max_source_bytes = 1024*1024*1024,
	max_entries = 1_000,
	max_path_bytes = 512,
	max_entry_bytes = 256*1024*1024,
	max_total_bytes = 1024*1024*1024,
	max_compression_ratio = 200,
}

DEFAULT_3MF_ZIP_LIMITS :: DEFAULT_BOUNDED_ZIP_LIMITS

Bounded_Zip_Entry :: struct {
	name:              string,
	flags:             u16,
	method:            u16,
	crc32:             u32,
	compressed_bytes:  u32,
	uncompressed_bytes: u32,
	local_header_offset: u32,
}

Bounded_Zip_Archive :: struct {
	source:  []u8,
	entries: []Bounded_Zip_Entry,
}

Bounded_Zip_Error :: enum u8 {
	None,
	Truncated,
	Source_Size_Limit,
	End_Record,
	Multi_Disk,
	Zip64_Unsupported,
	Entry_Limit,
	Path_Limit,
	Invalid_Path,
	Duplicate_Path,
	Unsupported_Flags,
	Unsupported_Method,
	Entry_Size_Limit,
	Total_Size_Limit,
	Compression_Ratio,
	Central_Directory,
	Local_Header,
	Size_Mismatch,
	Inflate_Failed,
	CRC_Mismatch,
	Allocation_Failed,
}

bounded_zip_parse :: proc(
	source: []u8,
	limits := DEFAULT_3MF_ZIP_LIMITS,
	allocator := context.allocator,
) -> (Bounded_Zip_Archive, Bounded_Zip_Error) {
	if len(source) < 22 {return {}, .Truncated}
	if u64(len(source)) > limits.max_source_bytes {
		return {}, .Source_Size_Limit
	}
	end_offset, end_ok := bounded_zip_find_end(source)
	if !end_ok {return {}, .End_Record}
	disk_number := bounded_zip_read_u16(source, end_offset+4)
	central_disk := bounded_zip_read_u16(source, end_offset+6)
	disk_entries := bounded_zip_read_u16(source, end_offset+8)
	total_entries := bounded_zip_read_u16(source, end_offset+10)
	central_size := bounded_zip_read_u32(source, end_offset+12)
	central_offset := bounded_zip_read_u32(source, end_offset+16)
	if disk_number != 0 || central_disk != 0 ||
	   disk_entries != total_entries {
		return {}, .Multi_Disk
	}
	if total_entries == 0xffff ||
	   central_size == 0xffff_ffff ||
	   central_offset == 0xffff_ffff {
		return {}, .Zip64_Unsupported
	}
	if u32(total_entries) > limits.max_entries {return {}, .Entry_Limit}
	central_end := u64(central_offset)+u64(central_size)
	if central_end > u64(end_offset) ||
	   u64(central_offset) > u64(len(source)) {
		return {}, .Central_Directory
	}

	archive := Bounded_Zip_Archive{source = source}
	archive.entries = make(
		[]Bounded_Zip_Entry,
		int(total_entries),
		allocator,
	)
	local_ends := make([]u64, int(total_entries), allocator)
	defer delete(local_ends, allocator)
	if total_entries > 0 &&
	   (archive.entries == nil || local_ends == nil) {
		bounded_zip_destroy(&archive, allocator)
		return {}, .Allocation_Failed
	}
	cursor := int(central_offset)
	total_uncompressed: u64
	for entry_index in 0..<int(total_entries) {
		if cursor < 0 || cursor+46 > len(source) ||
		   bounded_zip_read_u32(source, cursor) !=
		   	ZIP_CENTRAL_HEADER_SIGNATURE {
			bounded_zip_destroy(&archive, allocator)
			return {}, .Central_Directory
		}
		flags := bounded_zip_read_u16(source, cursor+8)
		method := bounded_zip_read_u16(source, cursor+10)
		crc32 := bounded_zip_read_u32(source, cursor+16)
		compressed_bytes := bounded_zip_read_u32(source, cursor+20)
		uncompressed_bytes := bounded_zip_read_u32(source, cursor+24)
		name_length := bounded_zip_read_u16(source, cursor+28)
		extra_length := bounded_zip_read_u16(source, cursor+30)
		comment_length := bounded_zip_read_u16(source, cursor+32)
		disk_start := bounded_zip_read_u16(source, cursor+34)
		local_offset := bounded_zip_read_u32(source, cursor+42)
		if compressed_bytes == 0xffff_ffff ||
		   uncompressed_bytes == 0xffff_ffff ||
		   local_offset == 0xffff_ffff {
			bounded_zip_destroy(&archive, allocator)
			return {}, .Zip64_Unsupported
		}
		if disk_start != 0 {
			bounded_zip_destroy(&archive, allocator)
			return {}, .Multi_Disk
		}
		if flags&~u16(0x080e) != 0 || flags&1 != 0 {
			bounded_zip_destroy(&archive, allocator)
			return {}, .Unsupported_Flags
		}
		if method != 0 && method != 8 {
			bounded_zip_destroy(&archive, allocator)
			return {}, .Unsupported_Method
		}
		if name_length == 0 ||
		   u32(name_length) > limits.max_path_bytes {
			bounded_zip_destroy(&archive, allocator)
			return {}, .Path_Limit
		}
		record_end := u64(cursor)+46+u64(name_length)+
			u64(extra_length)+u64(comment_length)
		if record_end > central_end || record_end > u64(len(source)) {
			bounded_zip_destroy(&archive, allocator)
			return {}, .Central_Directory
		}
		name_start := cursor+46
		name := string(source[name_start:name_start+int(name_length)])
		is_directory := name[len(name)-1] == '/'
		if !bounded_zip_entry_path_valid(name, is_directory) ||
		   (is_directory && uncompressed_bytes != 0) {
			bounded_zip_destroy(&archive, allocator)
			return {}, .Invalid_Path
		}
		for previous_index in 0..<entry_index {
			if archive.entries[previous_index].name == name {
				bounded_zip_destroy(&archive, allocator)
				return {}, .Duplicate_Path
			}
		}
		if u64(uncompressed_bytes) > limits.max_entry_bytes {
			bounded_zip_destroy(&archive, allocator)
			return {}, .Entry_Size_Limit
		}
		if uncompressed_bytes > 0 &&
		   (compressed_bytes == 0 ||
		    u64(uncompressed_bytes) >
		    	u64(compressed_bytes)*u64(limits.max_compression_ratio)) {
			bounded_zip_destroy(&archive, allocator)
			return {}, .Compression_Ratio
		}
		if u64(uncompressed_bytes) > limits.max_total_bytes ||
		   total_uncompressed >
		   	limits.max_total_bytes-u64(uncompressed_bytes) {
			bounded_zip_destroy(&archive, allocator)
			return {}, .Total_Size_Limit
		}
		total_uncompressed += u64(uncompressed_bytes)
		if u64(local_offset)+30 > u64(central_offset) {
			bounded_zip_destroy(&archive, allocator)
			return {}, .Local_Header
		}
		local_end, local_ok := bounded_zip_validate_local_record(
			source,
			local_offset,
			u64(central_offset),
			name,
			flags,
			method,
			crc32,
			compressed_bytes,
			uncompressed_bytes,
		)
		if !local_ok {
			bounded_zip_destroy(&archive, allocator)
			return {}, .Local_Header
		}
		local_start := u64(local_offset)
		for previous_index in 0..<entry_index {
			previous_start := u64(
				archive.entries[previous_index].local_header_offset,
			)
			previous_end := local_ends[previous_index]
			if local_start < previous_end &&
			   previous_start < local_end {
				bounded_zip_destroy(&archive, allocator)
				return {}, .Local_Header
			}
		}
		cloned_name := strings.clone(name, allocator)
		if cloned_name == "" {
			bounded_zip_destroy(&archive, allocator)
			return {}, .Allocation_Failed
		}
		archive.entries[entry_index] = {
			name = cloned_name,
			flags = flags,
			method = method,
			crc32 = crc32,
			compressed_bytes = compressed_bytes,
			uncompressed_bytes = uncompressed_bytes,
			local_header_offset = local_offset,
		}
		local_ends[entry_index] = local_end
		cursor = int(record_end)
	}
	if cursor != int(central_end) {
		bounded_zip_destroy(&archive, allocator)
		return {}, .Central_Directory
	}
	return archive, .None
}

bounded_zip_validate_local_record :: proc(
	source: []u8,
	local_offset: u32,
	central_offset: u64,
	name: string,
	flags, method: u16,
	crc32, compressed_bytes, uncompressed_bytes: u32,
) -> (u64, bool) {
	offset := u64(local_offset)
	if offset+30 > central_offset ||
	   offset+30 > u64(len(source)) ||
	   bounded_zip_read_u32(source, int(offset)) !=
	   	ZIP_LOCAL_HEADER_SIGNATURE {
		return 0, false
	}
	local_flags := bounded_zip_read_u16(source, int(offset)+6)
	local_method := bounded_zip_read_u16(source, int(offset)+8)
	local_crc := bounded_zip_read_u32(source, int(offset)+14)
	local_compressed := bounded_zip_read_u32(source, int(offset)+18)
	local_uncompressed := bounded_zip_read_u32(source, int(offset)+22)
	name_length := bounded_zip_read_u16(source, int(offset)+26)
	extra_length := bounded_zip_read_u16(source, int(offset)+28)
	header_end := offset+30+u64(name_length)+u64(extra_length)
	data_end := header_end+u64(compressed_bytes)
	if local_flags != flags || local_method != method ||
	   header_end > central_offset || data_end > central_offset ||
	   data_end > u64(len(source)) {
		return 0, false
	}
	local_name := string(
		source[int(offset)+30:int(offset)+30+int(name_length)],
	)
	if local_name != name {return 0, false}
	has_descriptor := flags&(u16(1)<<3) != 0
	if !has_descriptor {
		if local_crc != crc32 ||
		   local_compressed != compressed_bytes ||
		   local_uncompressed != uncompressed_bytes {
			return 0, false
		}
		return data_end, true
	}
	if (local_crc != 0 && local_crc != crc32) ||
	   (local_compressed != 0 && local_compressed != compressed_bytes) ||
	   (local_uncompressed != 0 &&
	    local_uncompressed != uncompressed_bytes) {
		return 0, false
	}
	descriptor_cursor := data_end
	if descriptor_cursor+4 <= central_offset &&
	   bounded_zip_read_u32(source, int(descriptor_cursor)) ==
	   	ZIP_DATA_DESCRIPTOR_SIGNATURE {
		descriptor_cursor += 4
	}
	if descriptor_cursor+12 > central_offset ||
	   descriptor_cursor+12 > u64(len(source)) ||
	   bounded_zip_read_u32(source, int(descriptor_cursor)) != crc32 ||
	   bounded_zip_read_u32(source, int(descriptor_cursor)+4) !=
	   	compressed_bytes ||
	   bounded_zip_read_u32(source, int(descriptor_cursor)+8) !=
	   	uncompressed_bytes {
		return 0, false
	}
	return descriptor_cursor+12, true
}

bounded_zip_extract :: proc(
	archive: Bounded_Zip_Archive,
	entry_index: int,
	allocator := context.allocator,
) -> ([]u8, Bounded_Zip_Error) {
	if entry_index < 0 || entry_index >= len(archive.entries) {
		return nil, .Local_Header
	}
	entry := archive.entries[entry_index]
	offset := int(entry.local_header_offset)
	source := archive.source
	if offset < 0 || offset+30 > len(source) ||
	   bounded_zip_read_u32(source, offset) != ZIP_LOCAL_HEADER_SIGNATURE {
		return nil, .Local_Header
	}
	flags := bounded_zip_read_u16(source, offset+6)
	method := bounded_zip_read_u16(source, offset+8)
	local_crc := bounded_zip_read_u32(source, offset+14)
	local_compressed := bounded_zip_read_u32(source, offset+18)
	local_uncompressed := bounded_zip_read_u32(source, offset+22)
	name_length := bounded_zip_read_u16(source, offset+26)
	extra_length := bounded_zip_read_u16(source, offset+28)
	header_end := u64(offset)+30+u64(name_length)+u64(extra_length)
	data_end := header_end+u64(entry.compressed_bytes)
	if flags != entry.flags || method != entry.method ||
	   header_end > u64(len(source)) || data_end > u64(len(source)) {
		return nil, .Local_Header
	}
	local_name := string(
		source[offset+30:offset+30+int(name_length)],
	)
	if local_name != entry.name {return nil, .Local_Header}
	if flags&(u16(1)<<3) == 0 &&
	   (local_crc != entry.crc32 ||
	    local_compressed != entry.compressed_bytes ||
	    local_uncompressed != entry.uncompressed_bytes) {
		return nil, .Size_Mismatch
	}
	compressed := source[int(header_end):int(data_end)]
	output: []u8
	if entry.method == 0 {
		if entry.compressed_bytes != entry.uncompressed_bytes {
			return nil, .Size_Mismatch
		}
		output = make([]u8, int(entry.uncompressed_bytes), allocator)
		if entry.uncompressed_bytes > 0 && output == nil {
			return nil, .Allocation_Failed
		}
		copy(output, compressed)
	} else {
		buffer: bytes.Buffer
		bytes.buffer_init_allocator(
			&buffer,
			0,
			int(entry.uncompressed_bytes),
			allocator,
		)
		defer bytes.buffer_destroy(&buffer)
		inflate_error := zlib.inflate(
			input = compressed,
			buf = &buffer,
			raw = true,
			expected_output_size = int(entry.uncompressed_bytes),
		)
		if inflate_error != nil {return nil, .Inflate_Failed}
		inflated := bytes.buffer_to_bytes(&buffer)
		if len(inflated) != int(entry.uncompressed_bytes) {
			return nil, .Size_Mismatch
		}
		output = make([]u8, len(inflated), allocator)
		if len(inflated) > 0 && output == nil {
			return nil, .Allocation_Failed
		}
		copy(output, inflated)
	}
	if bounded_zip_crc32(output) != entry.crc32 {
		delete(output, allocator)
		return nil, .CRC_Mismatch
	}
	return output, .None
}

bounded_zip_find :: proc(
	archive: Bounded_Zip_Archive,
	name: string,
) -> (int, bool) {
	for entry, entry_index in archive.entries {
		if entry.name == name {return entry_index, true}
	}
	return 0, false
}

bounded_zip_find_end :: proc(source: []u8) -> (int, bool) {
	minimum := max(0, len(source)-22-ZIP_MAX_COMMENT_BYTES)
	for offset := len(source)-22; offset >= minimum; offset -= 1 {
		if bounded_zip_read_u32(source, offset) != ZIP_END_SIGNATURE {
			continue
		}
		comment_length := bounded_zip_read_u16(source, offset+20)
		if offset+22+int(comment_length) == len(source) {
			return offset, true
		}
	}
	return 0, false
}

bounded_zip_path_valid :: proc(path: string) -> bool {
	return bounded_zip_entry_path_valid(path, false)
}

bounded_zip_entry_path_valid :: proc(
	path: string,
	allow_directory: bool,
) -> bool {
	if path == "" || path[0] == '/' || !utf8.valid_string(path) {
		return false
	}
	path_end := len(path)
	if path[path_end-1] == '/' {
		if !allow_directory || path_end == 1 {return false}
		path_end -= 1
	}
	component_start := 0
	for value, index in path[:path_end] {
		if value < 0x20 || value == 0x7f ||
		   value == '\\' || value == ':' {
			return false
		}
		if value != '/' {continue}
		component := path[component_start:index]
		if component == "" || component == "." || component == ".." {
			return false
		}
		component_start = index+1
	}
	component := path[component_start:path_end]
	return component != "" && component != "." && component != ".."
}

bounded_zip_crc32 :: proc(data: []u8) -> u32 {
	crc := u32(0xffff_ffff)
	for value in data {
		crc ~= u32(value)
		for _ in 0..<8 {
			mask := u32(0)-u32(crc&1)
			crc = (crc>>1)~(0xedb8_8320&mask)
		}
	}
	return ~crc
}

bounded_zip_read_u16 :: proc(source: []u8, offset: int) -> u16 {
	return u16(source[offset]) | u16(source[offset+1])<<8
}

bounded_zip_read_u32 :: proc(source: []u8, offset: int) -> u32 {
	return u32(source[offset]) |
		u32(source[offset+1])<<8 |
		u32(source[offset+2])<<16 |
		u32(source[offset+3])<<24
}

bounded_zip_destroy :: proc(
	archive: ^Bounded_Zip_Archive,
	allocator := context.allocator,
) {
	for entry in archive.entries {
		delete(entry.name, allocator)
	}
	delete(archive.entries, allocator)
	archive^ = {}
}
