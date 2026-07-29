/*
 * Odin uses upstream LLVM 21 instrumentation. Xcode 26 supplies Apple's LLVM
 * 21 ASan runtime. Route the upstream version guard to Apple's exact guard.
 */
extern void __asan_version_mismatch_check_apple_clang_2100(void);

void __asan_version_mismatch_check_v8(void) {
    __asan_version_mismatch_check_apple_clang_2100();
}
