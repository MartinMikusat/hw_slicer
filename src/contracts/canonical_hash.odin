package contracts

import crypto_hash "core:crypto/hash"

CANONICAL_HASH_FORMAT_VERSION :: u32(1)
CANONICAL_HASH_MAGIC :: "HW-SLICER-CANONICAL\x00"

Canonical_Hash :: struct {
	ctx: crypto_hash.Context,
}

canonical_hash_init :: proc(
	hash: ^Canonical_Hash,
	domain: string,
	schema_version: u32,
) {
	crypto_hash.init(&hash.ctx, .SHA256)
	magic: string = CANONICAL_HASH_MAGIC
	crypto_hash.update(
		&hash.ctx,
		transmute([]byte)magic,
	)
	canonical_hash_append_u32(hash, CANONICAL_HASH_FORMAT_VERSION)
	canonical_hash_append_string(hash, domain)
	canonical_hash_append_u32(hash, schema_version)
}

canonical_hash_append_u8 :: proc(hash: ^Canonical_Hash, value: u8) {
	bytes := [1]byte{value}
	crypto_hash.update(&hash.ctx, bytes[:])
}

canonical_hash_append_u32 :: proc(hash: ^Canonical_Hash, value: u32) {
	bytes := [4]byte{
		byte(value),
		byte(value>>8),
		byte(value>>16),
		byte(value>>24),
	}
	crypto_hash.update(&hash.ctx, bytes[:])
}

canonical_hash_append_u64 :: proc(hash: ^Canonical_Hash, value: u64) {
	bytes: [8]byte
	for byte_index in 0..<len(bytes) {
		bytes[byte_index] = byte(value>>u64(byte_index*8))
	}
	crypto_hash.update(&hash.ctx, bytes[:])
}

canonical_hash_append_i64 :: proc(hash: ^Canonical_Hash, value: i64) {
	canonical_hash_append_u64(hash, transmute(u64)value)
}

canonical_hash_append_i128 :: proc(hash: ^Canonical_Hash, value: i128) {
	unsigned := transmute(u128)value
	canonical_hash_append_u64(hash, u64(unsigned))
	canonical_hash_append_u64(hash, u64(unsigned>>64))
}

canonical_hash_append_f64_bits :: proc(hash: ^Canonical_Hash, value: f64) {
	canonical_hash_append_u64(hash, transmute(u64)value)
}

canonical_hash_append_stable_id :: proc(
	hash: ^Canonical_Hash,
	value: Stable_ID,
) {
	canonical_hash_append_u64(hash, u64(value))
}

canonical_hash_append_content_hash :: proc(
	hash: ^Canonical_Hash,
	value: Content_Hash,
) {
	bytes := value
	crypto_hash.update(&hash.ctx, bytes[:])
}

canonical_hash_append_bytes :: proc(hash: ^Canonical_Hash, value: []u8) {
	canonical_hash_append_u64(hash, u64(len(value)))
	crypto_hash.update(&hash.ctx, value)
}

canonical_hash_append_string :: proc(hash: ^Canonical_Hash, value: string) {
	canonical_hash_append_bytes(hash, transmute([]u8)value)
}

canonical_hash_final :: proc(hash: ^Canonical_Hash) -> Content_Hash {
	result: Content_Hash
	crypto_hash.final(&hash.ctx, result[:])
	return result
}
