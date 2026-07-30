package formats

import "core:os"

Source_File_Read_Error :: enum u8 {
	None,
	Open_Failed,
	Size_Limit,
	Allocation_Failed,
	Read_Failed,
	Changed_During_Read,
}

source_file_read_bounded :: proc(
	path: string,
	minimum_byte_count, maximum_byte_count: u64,
	allocator := context.allocator,
) -> ([]u8, Source_File_Read_Error) {
	if minimum_byte_count > maximum_byte_count ||
	   maximum_byte_count > u64(max(int)) {
		return nil, .Size_Limit
	}
	handle, open_error := os.open(path)
	if open_error != nil {return nil, .Open_Failed}
	defer os.close(handle)
	byte_count, size_error := os.file_size(handle)
	if size_error != nil ||
	   byte_count < 0 ||
	   u64(byte_count) < minimum_byte_count ||
	   u64(byte_count) > maximum_byte_count {
		return nil, .Size_Limit
	}
	bytes := make([]u8, int(byte_count), allocator)
	if byte_count > 0 && bytes == nil {return nil, .Allocation_Failed}
	bytes_read, read_error := os.read_full(handle, bytes)
	if read_error != nil || bytes_read != len(bytes) {
		delete(bytes, allocator)
		return nil, .Read_Failed
	}
	extra: [1]u8
	extra_count, extra_error := os.read(handle, extra[:])
	if extra_error != nil || extra_count != 0 {
		delete(bytes, allocator)
		return nil, .Changed_During_Read
	}
	return bytes, .None
}
