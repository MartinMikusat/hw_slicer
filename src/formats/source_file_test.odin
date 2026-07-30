package formats

import "core:mem"
import "core:testing"

@(test)
source_file_reader_checks_size_before_allocation_test :: proc(t: ^testing.T) {
	path := "testdata/ascii-stl/tetrahedron.stl"
	bytes, read_error := source_file_read_bounded(path, 1, 1024*1024)
	defer delete(bytes)
	testing.expect_value(t, read_error, Source_File_Read_Error.None)
	testing.expect(t, len(bytes) > 0)

	_, maximum_error := source_file_read_bounded(
		path,
		1,
		u64(len(bytes)-1),
	)
	testing.expect_value(
		t,
		maximum_error,
		Source_File_Read_Error.Size_Limit,
	)
	_, minimum_error := source_file_read_bounded(
		path,
		u64(len(bytes)+1),
		u64(len(bytes)+1),
	)
	testing.expect_value(
		t,
		minimum_error,
		Source_File_Read_Error.Size_Limit,
	)
	_, invalid_limit_error := source_file_read_bounded(path, 2, 1)
	testing.expect_value(
		t,
		invalid_limit_error,
		Source_File_Read_Error.Size_Limit,
	)
	_, missing_error := source_file_read_bounded(
		"testdata/does-not-exist.stl",
		1,
		1024,
	)
	testing.expect_value(
		t,
		missing_error,
		Source_File_Read_Error.Open_Failed,
	)
	_, allocation_error := source_file_read_bounded(
		path,
		1,
		1024*1024,
		mem.nil_allocator(),
	)
	testing.expect_value(
		t,
		allocation_error,
		Source_File_Read_Error.Allocation_Failed,
	)
}
