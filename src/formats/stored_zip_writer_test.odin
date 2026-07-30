package formats

import "core:crypto/sha2"
import "core:mem"
import "core:testing"

@(test)
bounded_stored_zip_writer_is_canonical_and_round_trips_test :: proc(
	t: ^testing.T,
) {
	left := "left"
	right := "right"
	entries := [2]Bounded_Zip_Write_Entry{
		{"z/right.txt", transmute([]u8)right},
		{"a/left.txt", transmute([]u8)left},
	}
	first, first_error := bounded_zip_write_stored(entries[:])
	defer delete(first)
	reversed := [2]Bounded_Zip_Write_Entry{entries[1], entries[0]}
	second, second_error := bounded_zip_write_stored(reversed[:])
	defer delete(second)
	testing.expect_value(t, first_error, Bounded_Zip_Error.None)
	testing.expect_value(t, second_error, Bounded_Zip_Error.None)
	testing.expect_value(t, string(first), string(second))
	testing.expect_value(t, bounded_zip_read_u16(first, 10), u16(0))
	testing.expect_value(t, bounded_zip_read_u16(first, 12), u16(33))
	archive, parse_error := bounded_zip_parse(first)
	defer bounded_zip_destroy(&archive)
	testing.expect_value(t, parse_error, Bounded_Zip_Error.None)
	testing.expect_value(t, archive.entries[0].name, "a/left.txt")
	testing.expect_value(t, archive.entries[1].name, "z/right.txt")
	for entry, entry_index in archive.entries {
		testing.expect_value(t, entry.flags, u16(0x0800))
		testing.expect_value(t, entry.method, u16(0))
		extracted, extract_error := bounded_zip_extract(
			archive,
			entry_index,
		)
		testing.expect_value(t, extract_error, Bounded_Zip_Error.None)
		expected := left if entry.name == "a/left.txt" else right
		testing.expect_value(t, string(extracted), expected)
		delete(extracted)
	}
	digest: [sha2.DIGEST_SIZE_256]u8
	hash_context: sha2.Context_256
	sha2.init_256(&hash_context)
	sha2.update(&hash_context, first)
	sha2.final(&hash_context, digest[:])
	expected_digest := [sha2.DIGEST_SIZE_256]u8{
		0x25, 0xcc, 0x50, 0x03, 0x20, 0xc2, 0x1c, 0x67,
		0xf8, 0x68, 0x85, 0x4f, 0xf2, 0x9a, 0x9b, 0xd8,
		0xbf, 0xbf, 0xb3, 0x3c, 0x12, 0x07, 0x4a, 0x39,
		0x09, 0x3f, 0x27, 0x95, 0xb2, 0xa3, 0x98, 0xce,
	}
	testing.expect_value(t, digest, expected_digest)
}

@(test)
bounded_stored_zip_writer_rejects_paths_duplicates_and_limits_test :: proc(
	t: ^testing.T,
) {
	value := "x"
	invalid := [1]Bounded_Zip_Write_Entry{
		{"../outside", transmute([]u8)value},
	}
	_, path_error := bounded_zip_write_stored(invalid[:])
	testing.expect_value(t, path_error, Bounded_Zip_Error.Invalid_Path)

	duplicates := [2]Bounded_Zip_Write_Entry{
		{"same", transmute([]u8)value},
		{"same", transmute([]u8)value},
	}
	_, duplicate_error := bounded_zip_write_stored(duplicates[:])
	testing.expect_value(
		t,
		duplicate_error,
		Bounded_Zip_Error.Duplicate_Path,
	)

	valid := [1]Bounded_Zip_Write_Entry{
		{"value", transmute([]u8)value},
	}
	limits := DEFAULT_3MF_ZIP_LIMITS
	limits.max_entry_bytes = 0
	_, entry_error := bounded_zip_write_stored(valid[:], limits)
	testing.expect_value(
		t,
		entry_error,
		Bounded_Zip_Error.Entry_Size_Limit,
	)
	limits = DEFAULT_3MF_ZIP_LIMITS
	limits.max_source_bytes = 1
	_, source_error := bounded_zip_write_stored(valid[:], limits)
	testing.expect_value(
		t,
		source_error,
		Bounded_Zip_Error.Source_Size_Limit,
	)
	_, allocation_error := bounded_zip_write_stored(
		valid[:],
		DEFAULT_BOUNDED_ZIP_LIMITS,
		mem.nil_allocator(),
	)
	testing.expect_value(
		t,
		allocation_error,
		Bounded_Zip_Error.Allocation_Failed,
	)
}
