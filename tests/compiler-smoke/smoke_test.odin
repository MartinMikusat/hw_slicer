package compiler_smoke

import "core:simd"
import "core:sync"
import "core:testing"

@(thread_local)
compiler_smoke_thread_value: u64

Compiler_Smoke_Callback :: #type proc "c" (value: u64) -> u64

compiler_smoke_callback :: proc "c" (value: u64) -> u64 {
	return value+1
}

Metal_Size_Smoke :: struct {
	width:  uint,
	height: uint,
	depth:  uint,
}

@(test)
compiler_supports_i128_geometry_intermediates_test :: proc(t: ^testing.T) {
	a := i128(1)<<100
	b := i128(1)<<60
	testing.expect_value(t, a/b, i128(1)<<40)
}

@(test)
compiler_supports_arm64_simd_vectors_test :: proc(t: ^testing.T) {
	a: simd.f32x4 = {1, 2, 3, 4}
	b: simd.f32x4 = {5, 6, 7, 8}
	result := transmute([4]f32)simd.add(a, b)
	testing.expect_value(t, result[0], f32(6))
	testing.expect_value(t, result[3], f32(12))
}

@(test)
compiler_supports_explicit_atomic_ordering_test :: proc(t: ^testing.T) {
	value: u64
	sync.atomic_store_explicit(&value, 42, .Release)
	loaded := sync.atomic_load_explicit(&value, .Acquire)
	testing.expect_value(t, loaded, u64(42))
}

@(test)
compiler_supports_thread_local_state_test :: proc(t: ^testing.T) {
	compiler_smoke_thread_value = 17
	testing.expect_value(t, compiler_smoke_thread_value, u64(17))
}

@(test)
compiler_supports_c_abi_callbacks_test :: proc(t: ^testing.T) {
	callback: Compiler_Smoke_Callback = compiler_smoke_callback
	testing.expect_value(t, callback(9), u64(10))
}

@(test)
metal_value_struct_layout_matches_arm64_abi_test :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Metal_Size_Smoke), 24)
	testing.expect_value(t, align_of(Metal_Size_Smoke), 8)
}
