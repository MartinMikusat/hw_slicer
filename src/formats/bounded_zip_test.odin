package formats

import "core:testing"

bounded_zip_test_append_u16 :: proc(bytes: ^[dynamic]u8, value: u16) {
	append(bytes, u8(value), u8(value>>8))
}

bounded_zip_test_append_u32 :: proc(bytes: ^[dynamic]u8, value: u32) {
	append(
		bytes,
		u8(value),
		u8(value>>8),
		u8(value>>16),
		u8(value>>24),
	)
}

bounded_zip_test_write_u32 :: proc(bytes: []u8, offset: int, value: u32) {
	bytes[offset] = u8(value)
	bytes[offset+1] = u8(value>>8)
	bytes[offset+2] = u8(value>>16)
	bytes[offset+3] = u8(value>>24)
}

bounded_zip_test_write_u16 :: proc(bytes: []u8, offset: int, value: u16) {
	bytes[offset] = u8(value)
	bytes[offset+1] = u8(value>>8)
}

bounded_zip_test_make_stored :: proc(
	name: string,
	data: string,
) -> [dynamic]u8 {
	return bounded_zip_test_make_entry(
		name,
		data,
		transmute([]u8)data,
		0,
	)
}

bounded_zip_test_make_entry :: proc(
	name: string,
	data: string,
	compressed: []u8,
	method: u16,
) -> [dynamic]u8 {
	result: [dynamic]u8
	crc := bounded_zip_crc32(transmute([]u8)data)
	bounded_zip_test_append_u32(&result, ZIP_LOCAL_HEADER_SIGNATURE)
	bounded_zip_test_append_u16(&result, 20)
	bounded_zip_test_append_u16(&result, 0)
	bounded_zip_test_append_u16(&result, method)
	bounded_zip_test_append_u16(&result, 0)
	bounded_zip_test_append_u16(&result, 0)
	bounded_zip_test_append_u32(&result, crc)
	bounded_zip_test_append_u32(&result, u32(len(compressed)))
	bounded_zip_test_append_u32(&result, u32(len(data)))
	bounded_zip_test_append_u16(&result, u16(len(name)))
	bounded_zip_test_append_u16(&result, 0)
	append(&result, ..transmute([]u8)name)
	append(&result, ..compressed)

	central_offset := len(result)
	bounded_zip_test_append_u32(&result, ZIP_CENTRAL_HEADER_SIGNATURE)
	bounded_zip_test_append_u16(&result, 20)
	bounded_zip_test_append_u16(&result, 20)
	bounded_zip_test_append_u16(&result, 0)
	bounded_zip_test_append_u16(&result, method)
	bounded_zip_test_append_u16(&result, 0)
	bounded_zip_test_append_u16(&result, 0)
	bounded_zip_test_append_u32(&result, crc)
	bounded_zip_test_append_u32(&result, u32(len(compressed)))
	bounded_zip_test_append_u32(&result, u32(len(data)))
	bounded_zip_test_append_u16(&result, u16(len(name)))
	bounded_zip_test_append_u16(&result, 0)
	bounded_zip_test_append_u16(&result, 0)
	bounded_zip_test_append_u16(&result, 0)
	bounded_zip_test_append_u16(&result, 0)
	bounded_zip_test_append_u32(&result, 0)
	bounded_zip_test_append_u32(&result, 0)
	append(&result, ..transmute([]u8)name)
	central_size := len(result)-central_offset

	bounded_zip_test_append_u32(&result, ZIP_END_SIGNATURE)
	bounded_zip_test_append_u16(&result, 0)
	bounded_zip_test_append_u16(&result, 0)
	bounded_zip_test_append_u16(&result, 1)
	bounded_zip_test_append_u16(&result, 1)
	bounded_zip_test_append_u32(&result, u32(central_size))
	bounded_zip_test_append_u32(&result, u32(central_offset))
	bounded_zip_test_append_u16(&result, 0)
	return result
}

Bounded_Zip_Test_Item :: struct {
	name: string,
	data: string,
}

bounded_zip_test_make_stored_many :: proc(
	items: []Bounded_Zip_Test_Item,
) -> [dynamic]u8 {
	result: [dynamic]u8
	local_offsets := make([]u32, len(items))
	crcs := make([]u32, len(items))
	defer delete(local_offsets)
	defer delete(crcs)
	for item, item_index in items {
		local_offsets[item_index] = u32(len(result))
		crcs[item_index] = bounded_zip_crc32(transmute([]u8)item.data)
		bounded_zip_test_append_u32(&result, ZIP_LOCAL_HEADER_SIGNATURE)
		bounded_zip_test_append_u16(&result, 20)
		bounded_zip_test_append_u16(&result, 0)
		bounded_zip_test_append_u16(&result, 0)
		bounded_zip_test_append_u16(&result, 0)
		bounded_zip_test_append_u16(&result, 0)
		bounded_zip_test_append_u32(&result, crcs[item_index])
		bounded_zip_test_append_u32(&result, u32(len(item.data)))
		bounded_zip_test_append_u32(&result, u32(len(item.data)))
		bounded_zip_test_append_u16(&result, u16(len(item.name)))
		bounded_zip_test_append_u16(&result, 0)
		append(&result, ..transmute([]u8)item.name)
		append(&result, ..transmute([]u8)item.data)
	}
	central_offset := len(result)
	for item, item_index in items {
		bounded_zip_test_append_u32(
			&result,
			ZIP_CENTRAL_HEADER_SIGNATURE,
		)
		bounded_zip_test_append_u16(&result, 20)
		bounded_zip_test_append_u16(&result, 20)
		bounded_zip_test_append_u16(&result, 0)
		bounded_zip_test_append_u16(&result, 0)
		bounded_zip_test_append_u16(&result, 0)
		bounded_zip_test_append_u16(&result, 0)
		bounded_zip_test_append_u32(&result, crcs[item_index])
		bounded_zip_test_append_u32(&result, u32(len(item.data)))
		bounded_zip_test_append_u32(&result, u32(len(item.data)))
		bounded_zip_test_append_u16(&result, u16(len(item.name)))
		bounded_zip_test_append_u16(&result, 0)
		bounded_zip_test_append_u16(&result, 0)
		bounded_zip_test_append_u16(&result, 0)
		bounded_zip_test_append_u16(&result, 0)
		bounded_zip_test_append_u32(&result, 0)
		bounded_zip_test_append_u32(
			&result,
			local_offsets[item_index],
		)
		append(&result, ..transmute([]u8)item.name)
	}
	central_size := len(result)-central_offset
	bounded_zip_test_append_u32(&result, ZIP_END_SIGNATURE)
	bounded_zip_test_append_u16(&result, 0)
	bounded_zip_test_append_u16(&result, 0)
	bounded_zip_test_append_u16(&result, u16(len(items)))
	bounded_zip_test_append_u16(&result, u16(len(items)))
	bounded_zip_test_append_u32(&result, u32(central_size))
	bounded_zip_test_append_u32(&result, u32(central_offset))
	bounded_zip_test_append_u16(&result, 0)
	return result
}

@(test)
bounded_zip_parses_and_extracts_a_stored_model_part_test :: proc(
	t: ^testing.T,
) {
	source := bounded_zip_test_make_stored(
		"3D/3dmodel.model",
		"<model/>",
	)
	defer delete(source)
	archive, parse_error := bounded_zip_parse(source[:])
	defer bounded_zip_destroy(&archive)
	testing.expect_value(t, parse_error, Bounded_Zip_Error.None)
	testing.expect_value(t, len(archive.entries), 1)
	entry_index, found := bounded_zip_find(
		archive,
		"3D/3dmodel.model",
	)
	testing.expect(t, found)
	extracted, extract_error := bounded_zip_extract(
		archive,
		entry_index,
	)
	defer delete(extracted)
	testing.expect_value(t, extract_error, Bounded_Zip_Error.None)
	testing.expect_value(t, string(extracted), "<model/>")
}

@(test)
bounded_zip_extracts_a_raw_deflate_entry_test :: proc(t: ^testing.T) {
	compressed := [10]u8{179, 201, 205, 79, 73, 205, 209, 183, 3, 0}
	source := bounded_zip_test_make_entry(
		"3D/3dmodel.model",
		"<model/>",
		compressed[:],
		8,
	)
	defer delete(source)
	archive, parse_error := bounded_zip_parse(source[:])
	defer bounded_zip_destroy(&archive)
	testing.expect_value(t, parse_error, Bounded_Zip_Error.None)
	extracted, extract_error := bounded_zip_extract(archive, 0)
	defer delete(extracted)
	testing.expect_value(t, extract_error, Bounded_Zip_Error.None)
	testing.expect_value(t, string(extracted), "<model/>")
}

@(test)
bounded_zip_rejects_traversal_paths_and_entry_limits_test :: proc(
	t: ^testing.T,
) {
	source := bounded_zip_test_make_stored("../3D/model.model", "x")
	defer delete(source)
	_, path_error := bounded_zip_parse(source[:])
	valid := bounded_zip_test_make_stored("3D/model.model", "x")
	defer delete(valid)
	_, limit_error := bounded_zip_parse(
		valid[:],
		{
			max_source_bytes = 1024,
			max_entries = 0,
			max_path_bytes = 512,
			max_entry_bytes = 1,
			max_total_bytes = 1,
			max_compression_ratio = 1,
		},
	)
	source_limits := DEFAULT_3MF_ZIP_LIMITS
	source_limits.max_source_bytes = 1
	_, source_limit_error := bounded_zip_parse(valid[:], source_limits)
	testing.expect_value(t, path_error, Bounded_Zip_Error.Invalid_Path)
	testing.expect_value(t, limit_error, Bounded_Zip_Error.Entry_Limit)
	testing.expect_value(
		t,
		source_limit_error,
		Bounded_Zip_Error.Source_Size_Limit,
	)
}

@(test)
bounded_zip_rejects_duplicate_entry_paths_test :: proc(t: ^testing.T) {
	items := [2]Bounded_Zip_Test_Item{
		{"same.bin", "left"},
		{"same.bin", "right"},
	}
	source := bounded_zip_test_make_stored_many(items[:])
	defer delete(source)
	_, parse_error := bounded_zip_parse(source[:])
	testing.expect_value(
		t,
		parse_error,
		Bounded_Zip_Error.Duplicate_Path,
	)
}

@(test)
bounded_zip_rejects_path_entry_total_and_ratio_limits_test :: proc(
	t: ^testing.T,
) {
	source := bounded_zip_test_make_stored("3D/model.model", "x")
	defer delete(source)

	limits := DEFAULT_BOUNDED_ZIP_LIMITS
	limits.max_path_bytes = 1
	_, path_error := bounded_zip_parse(source[:], limits)
	testing.expect_value(t, path_error, Bounded_Zip_Error.Path_Limit)

	limits = DEFAULT_BOUNDED_ZIP_LIMITS
	limits.max_entry_bytes = 0
	_, entry_error := bounded_zip_parse(source[:], limits)
	testing.expect_value(
		t,
		entry_error,
		Bounded_Zip_Error.Entry_Size_Limit,
	)

	limits = DEFAULT_BOUNDED_ZIP_LIMITS
	limits.max_total_bytes = 0
	_, total_error := bounded_zip_parse(source[:], limits)
	testing.expect_value(
		t,
		total_error,
		Bounded_Zip_Error.Total_Size_Limit,
	)

	limits = DEFAULT_BOUNDED_ZIP_LIMITS
	limits.max_compression_ratio = 0
	_, ratio_error := bounded_zip_parse(source[:], limits)
	testing.expect_value(
		t,
		ratio_error,
		Bounded_Zip_Error.Compression_Ratio,
	)
}

@(test)
bounded_zip_rejects_multidisk_zip64_flags_and_methods_test :: proc(
	t: ^testing.T,
) {
	multidisk := bounded_zip_test_make_stored("value", "x")
	defer delete(multidisk)
	end_offset := len(multidisk)-22
	bounded_zip_test_write_u16(multidisk[:], end_offset+4, 1)
	_, multidisk_error := bounded_zip_parse(multidisk[:])
	testing.expect_value(
		t,
		multidisk_error,
		Bounded_Zip_Error.Multi_Disk,
	)

	zip64 := bounded_zip_test_make_stored("value", "x")
	defer delete(zip64)
	end_offset = len(zip64)-22
	bounded_zip_test_write_u16(zip64[:], end_offset+8, 0xffff)
	bounded_zip_test_write_u16(zip64[:], end_offset+10, 0xffff)
	_, zip64_error := bounded_zip_parse(zip64[:])
	testing.expect_value(
		t,
		zip64_error,
		Bounded_Zip_Error.Zip64_Unsupported,
	)

	encrypted := bounded_zip_test_make_stored("value", "x")
	defer delete(encrypted)
	end_offset = len(encrypted)-22
	central_offset := int(bounded_zip_read_u32(encrypted[:], end_offset+16))
	bounded_zip_test_write_u16(encrypted[:], 6, 1)
	bounded_zip_test_write_u16(encrypted[:], central_offset+8, 1)
	_, encrypted_error := bounded_zip_parse(encrypted[:])
	testing.expect_value(
		t,
		encrypted_error,
		Bounded_Zip_Error.Unsupported_Flags,
	)

	unsupported := bounded_zip_test_make_stored("value", "x")
	defer delete(unsupported)
	end_offset = len(unsupported)-22
	central_offset =
		int(bounded_zip_read_u32(unsupported[:], end_offset+16))
	bounded_zip_test_write_u16(unsupported[:], 8, 99)
	bounded_zip_test_write_u16(unsupported[:], central_offset+10, 99)
	_, method_error := bounded_zip_parse(unsupported[:])
	testing.expect_value(
		t,
		method_error,
		Bounded_Zip_Error.Unsupported_Method,
	)
}

@(test)
bounded_zip_rejects_invalid_utf8_and_control_paths_test :: proc(
	t: ^testing.T,
) {
	invalid_utf8 := [2]u8{0xff, 'x'}
	invalid_utf8_source := bounded_zip_test_make_stored(
		string(invalid_utf8[:]),
		"x",
	)
	defer delete(invalid_utf8_source)
	_, invalid_utf8_error := bounded_zip_parse(invalid_utf8_source[:])
	testing.expect_value(
		t,
		invalid_utf8_error,
		Bounded_Zip_Error.Invalid_Path,
	)

	control_source := bounded_zip_test_make_stored("3D/\nmodel", "x")
	defer delete(control_source)
	_, control_error := bounded_zip_parse(control_source[:])
	testing.expect_value(
		t,
		control_error,
		Bounded_Zip_Error.Invalid_Path,
	)

	unicode_source := bounded_zip_test_make_stored("evidence/vrstva-ž.bin", "x")
	defer delete(unicode_source)
	unicode_archive, unicode_error := bounded_zip_parse(unicode_source[:])
	defer bounded_zip_destroy(&unicode_archive)
	testing.expect_value(t, unicode_error, Bounded_Zip_Error.None)
}

@(test)
bounded_zip_accepts_empty_directory_entries_test :: proc(t: ^testing.T) {
	items := [2]Bounded_Zip_Test_Item{
		{"3D/", ""},
		{"3D/model.model", "x"},
	}
	source := bounded_zip_test_make_stored_many(items[:])
	defer delete(source)
	archive, parse_error := bounded_zip_parse(source[:])
	defer bounded_zip_destroy(&archive)

	data_directory := bounded_zip_test_make_stored("3D/", "x")
	defer delete(data_directory)
	_, data_directory_error := bounded_zip_parse(data_directory[:])

	testing.expect_value(t, parse_error, Bounded_Zip_Error.None)
	testing.expect_value(t, len(archive.entries), 2)
	testing.expect_value(
		t,
		data_directory_error,
		Bounded_Zip_Error.Invalid_Path,
	)
}

@(test)
bounded_zip_validates_extracted_crc_test :: proc(t: ^testing.T) {
	source := bounded_zip_test_make_stored("3D/model.model", "payload")
	defer delete(source)
	archive, parse_error := bounded_zip_parse(source[:])
	defer bounded_zip_destroy(&archive)
	testing.expect_value(t, parse_error, Bounded_Zip_Error.None)
	source[30+len("3D/model.model")] ~= 1
	extracted, extract_error := bounded_zip_extract(archive, 0)
	defer delete(extracted)
	testing.expect_value(t, extract_error, Bounded_Zip_Error.CRC_Mismatch)
}

@(test)
bounded_zip_crc32_matches_the_standard_check_value_test :: proc(t: ^testing.T) {
	check_value := "123456789"
	testing.expect_value(
		t,
		bounded_zip_crc32(transmute([]u8)check_value),
		u32(0xcbf43926),
	)
}

@(test)
bounded_zip_rejects_inconsistent_and_overlapping_local_records_test :: proc(
	t: ^testing.T,
) {
	inconsistent := bounded_zip_test_make_stored("3D/model.model", "x")
	defer delete(inconsistent)
	inconsistent[8] = 8
	_, inconsistent_error := bounded_zip_parse(inconsistent[:])

	items := [2]Bounded_Zip_Test_Item{
		{"one", "1"},
		{"two", "2"},
	}
	overlapping := bounded_zip_test_make_stored_many(items[:])
	defer delete(overlapping)
	central_seen := 0
	for cursor in 0..<len(overlapping)-46 {
		if bounded_zip_read_u32(overlapping[:], cursor) !=
		   ZIP_CENTRAL_HEADER_SIGNATURE {
			continue
		}
		if central_seen == 1 {
			bounded_zip_test_write_u32(overlapping[:], cursor+42, 0)
			break
		}
		central_seen += 1
	}
	_, overlap_error := bounded_zip_parse(overlapping[:])
	testing.expect_value(
		t,
		inconsistent_error,
		Bounded_Zip_Error.Local_Header,
	)
	testing.expect_value(
		t,
		overlap_error,
		Bounded_Zip_Error.Local_Header,
	)
}
