/*
 * Xcode 26 instruments the Objective-C host with Apple's LLVM 21 version
 * guard. Odin links the upstream LLVM 21 ASan runtime. Route the Apple guard
 * to the runtime guard supplied by the Odin executable.
 */
extern void __asan_version_mismatch_check_v8(void);

void __asan_version_mismatch_check_apple_clang_2100(void) {
    __asan_version_mismatch_check_v8();
}
