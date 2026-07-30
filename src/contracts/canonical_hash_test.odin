package contracts

import "core:testing"

canonical_hash_fixture :: proc(parts: [2]string) -> Content_Hash {
	hash: Canonical_Hash
	canonical_hash_init(&hash, "fixture", 7)
	canonical_hash_append_u8(&hash, 0xab)
	canonical_hash_append_u32(&hash, 0x12345678)
	canonical_hash_append_u64(&hash, 0x0102030405060708)
	canonical_hash_append_i64(&hash, -2)
	canonical_hash_append_i128(
		&hash,
		i128(-0x0102030405060708090a0b0c0d0e0f10),
	)
	canonical_hash_append_f64_bits(&hash, 1.5)
	canonical_hash_append_stable_id(&hash, Stable_ID(0x8877665544332211))
	content_hash: Content_Hash
	for &value, byte_index in content_hash {
		value = u8(byte_index)
	}
	canonical_hash_append_content_hash(&hash, content_hash)
	canonical_hash_append_string(&hash, parts[0])
	canonical_hash_append_string(&hash, parts[1])
	return canonical_hash_final(&hash)
}

@(test)
canonical_hash_uses_explicit_little_endian_fields_test :: proc(t: ^testing.T) {
	expected := Content_Hash{
		0x23, 0x10, 0x9e, 0xd6, 0x77, 0x75, 0x7f, 0xf7,
		0x31, 0x4f, 0x42, 0x7a, 0xf3, 0x65, 0x43, 0x1d,
		0x62, 0x01, 0x22, 0x89, 0xd0, 0x5c, 0x99, 0xd1,
		0x90, 0x80, 0xfc, 0x5f, 0x2f, 0x18, 0x53, 0x9e,
	}
	actual := canonical_hash_fixture({"ab", "c"})
	testing.expect_value(t, actual, expected)
}

@(test)
canonical_hash_length_prefixes_variable_fields_test :: proc(t: ^testing.T) {
	left := canonical_hash_fixture({"ab", "c"})
	right := canonical_hash_fixture({"a", "bc"})
	testing.expect(t, left != right)
}
