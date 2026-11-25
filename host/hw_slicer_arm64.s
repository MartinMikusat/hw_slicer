// Apple Silicon (ARM64) hand-written assembly kernels for hw_slicer.
// Assembled with `clang -c` in build.sh and linked into both hw_slicer.app and hw-slicer-cli.

.text
.p2align 4

// ============================================================================
// _hw_klipper_scan_line_end_neon
//
// Scans `bytes[start:len]` 16 bytes at a time using ARM64 NEON + SHRN/RBIT/CLZ
// to locate the terminating '\n' while validating that every preceding byte is
// printable ASCII [0x20..0x7e].
//
// Signature:
//   i64 hw_klipper_scan_line_end_neon(const u8 *bytes, i64 len, i64 start)
//   x0 = bytes, x1 = len, x2 = start
// Returns:
//   index of '\n' (> start) on valid non-empty line, or -1 on invalid byte / empty / EOF.
// ============================================================================
.globl _hw_klipper_scan_line_end_neon
_hw_klipper_scan_line_end_neon:
    add     x3, x0, x2              // cur = bytes + start
    add     x6, x0, x1              // end = bytes + len
    mov     w8, #0x20
    dup     v30.16b, w8             // v30 = [0x20; 16]
    mov     w8, #0x7e
    dup     v31.16b, w8             // v31 = [0x7e; 16]

    sub     x7, x6, #16             // vec_end = end - 16
    cmp     x3, x7
    b.gt    L_klip_scalar

.p2align 4
L_klip_vec_loop:
    ldr     q0, [x3]
    cmhi    v1.16b, v0.16b, v31.16b // v > 0x7e
    cmhi    v2.16b, v30.16b, v0.16b // v < 0x20
    orr     v1.16b, v1.16b, v2.16b  // bad or '\n'
    shrn    v1.8b, v1.8h, #4        // 4 bits per byte lane in d1
    fmov    x4, d1
    cbnz    x4, L_klip_vec_hit
    add     x3, x3, #16
    cmp     x3, x7
    b.le    L_klip_vec_loop
    b       L_klip_scalar

L_klip_vec_hit:
    rbit    x4, x4
    clz     x4, x4
    lsr     x4, x4, #2              // exact byte offset 0..15
    ldrb    w5, [x3, x4]
    cmp     w5, #0x0a               // '\n'
    b.ne    L_klip_fail
    add     x3, x3, x4
    sub     x0, x3, x0              // byte_index = cur - bytes
    cmp     x0, x2                  // must be > start (non-empty line)
    b.le    L_klip_fail
    ret

L_klip_scalar:
    cmp     x3, x6
    b.ge    L_klip_fail
L_klip_scalar_loop:
    ldrb    w5, [x3]
    cmp     w5, #0x0a
    b.eq    L_klip_scalar_nl
    sub     w8, w5, #0x20
    cmp     w8, #(0x7e - 0x20)
    b.hi    L_klip_fail
    add     x3, x3, #1
    cmp     x3, x6
    b.lt    L_klip_scalar_loop
L_klip_fail:
    mov     x0, #-1
    ret

L_klip_scalar_nl:
    sub     x0, x3, x0
    cmp     x0, x2
    b.le    L_klip_fail
    ret


// ============================================================================
// _hw_vatti_snap_strip_pass1
//
// Hand-written ARM64 inner pair-filter for `vatti_snap_round` Pass 1 Y-strips.
// Scans all pairs (ai < aj) in `st[0..n_st]` (32-byte Strip_Entry structs)
// with zero bounds checks and pure 64-bit integer register arithmetic.
// Emits `(ai | (aj << 32))` into `out_pairs` ONLY for pairs that pass at least
// one exact cross-product snap pre-filter, proper intersection test, or
// collinearity test (~2-5% of overlapping pairs).
//
// Strip_Entry layout (32 bytes):
//   +0  min_x: i32
//   +4  min_y: i32
//   +8  max_y: i32
//   +12 ax:    i32
//   +16 ay:    i32
//   +20 bx:    i32
//   +24 by:    i32
//   +28 meta:  u32  (idx:24 | s0:6 << 24 | is_clip:1 << 30)
//
// Signature:
//   i64 hw_vatti_snap_strip_pass1(
//       const Strip_Entry *st,   // x0
//       i64 n_st,                // x1
//       u64 s_u32,               // x2
//       i64 skip_same_set,       // x3
//       u64 *out_pairs,          // x4
//       i64 out_cap              // x5
//   )
// Returns:
//   number of emitted pairs (>= 0), or -1 if out_pairs overflowed.
// ============================================================================
.p2align 4
.globl _hw_vatti_snap_strip_pass1
_hw_vatti_snap_strip_pass1:
    stp     x29, x30, [sp, #-96]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]
    stp     x27, x28, [sp, #80]

    // Fixed across entire call:
    // x0  = st base
    // x1  = n_st
    // x2  = s_u32
    // x3  = skip_same_set
    // x4  = out_pairs
    // x5  = out_cap
    // x6  = out_count
    mov     x6, #0
    cmp     x1, #2
    b.lt    L_vs_done

    mov     x7, #0                  // ai = 0
    mov     x19, x0                 // ptr_i = &st[0]

.p2align 4
L_vs_ai_loop:
    add     x8, x7, #1              // aj = ai + 1
    cmp     x8, x1
    b.ge    L_vs_done

    // Load Strip_Entry[ai] (32 bytes):
    ldp     w9, w10, [x19, #0]      // w9 = a.min_x, w10 = a.min_y
    ldp     w11, w12, [x19, #8]     // w11 = a.max_y, w12 = a.ax
    ldp     w13, w14, [x19, #16]    // w13 = a.ay,    w14 = a.bx
    ldp     w15, w16, [x19, #24]    // w15 = a.by,    w16 = a.meta

    // Sign-extend a's coordinates into callee-saved x20..x27:
    sxtw    x20, w12                // x20 = a_ax
    sxtw    x21, w13                // x21 = a_ay
    sxtw    x22, w14                // x22 = a_bx
    sxtw    x23, w15                // x23 = a_by

    // a_max_x = max(a_ax, a_bx) in x24, widened bounds in w25..w27:
    cmp     x20, x22
    csel    x24, x20, x22, ge       // x24 = a_max_x
    add     w25, w24, #1            // w25 = sa_max_x_1 (i32)
    sub     w26, w10, #1            // w26 = sa_min_y_1 (i32)
    add     w27, w11, #1            // w27 = sa_max_y_1 (i32)

    // dax = a_bx - a_ax (x28), day = a_by - a_ay (saved in stack? No: pack i_s0 & i_clip!)
    // Actually keep x28 = ptr_j, and recompute dax/day only when pair passes bbox+strip!
    // Wait: storing a_min_x/a_min_y/a_max_y/i_s0/i_clip:
    // Pack into stack slot? No, we have sp-relative scratch or registers!
    // Let's check free registers before aj loop:
    // x0..x6 fixed, x7=ai, x8=aj, x19=ptr_i, x20=a_ax, x21=a_ay, x22=a_bx, x23=a_by, x24=a_max_x
    // w25=sa_max_x_1, w26=sa_min_y_1, w27=sa_max_y_1, x28=ptr_j
    // Pack a_min_x(w9), a_min_y(w10), a_max_y(w11), a_meta(w16) into a_s0_clip in upper bits?
    // Even simpler: a_min_x = min(a_ax, a_bx), a_min_y = min(a_ay, a_by), a_max_y = max(a_ay, a_by)
    // and we can read [x19, #28] ONLY when a pair passes bbox! Wait: i_s0 is checked on every aj
    // that passes bbox! Put w16 (a.meta) in upper 32 bits of x25 (`bfi x25, x16, #32, #32`)!
    // ARM64 trick: w25 holds sa_max_x_1, upper 32 bits of x25 hold a.meta! Zero stack traffic!
    bfi     x25, x16, #32, #32      // x25[31:0] = sa_max_x_1, x25[63:32] = a.meta

    add     x28, x19, #32           // ptr_j = ptr_i + 32

.p2align 4
L_vs_aj_loop:
    // Hot rejection path: 4 instructions for X-break + Y-reject!
    ldr     w9, [x28, #0]           // w9 = b.min_x
    cmp     w9, w25                 // b.min_x > sa_max_x_1 ?
    b.gt    L_vs_next_ai            // BREAK out of aj loop!
    ldp     w10, w11, [x28, #4]     // w10 = b.min_y, w11 = b.max_y
    cmp     w11, w26                // b.max_y < sa_min_y_1 ?
    b.lt    L_vs_next_aj
    cmp     w10, w27                // b.min_y > sa_max_y_1 ?
    b.gt    L_vs_next_aj

    // Strip ownership deduplication: max(i_s0, j_s0) == s_u32
    ldr     w12, [x28, #28]         // w12 = b.meta
    ubfx    x13, x25, #56, #6       // i_s0 = (a.meta >> 24) & 0x3f
    ubfx    x14, x12, #24, #6       // j_s0 = (b.meta >> 24) & 0x3f
    cmp     x13, x14
    csel    x13, x13, x14, ge       // max(i_s0, j_s0)
    cmp     x13, x2                 // == s_u32 ?
    b.ne    L_vs_next_aj

    // Pair (ai, aj) has overlapping widened bboxes and belongs to strip s_u32.
    // Load b's endpoints:
    ldp     w13, w14, [x28, #12]    // w13 = b.ax, w14 = b.ay
    ldp     w15, w16, [x28, #20]    // w15 = b.bx, w16 = b.by
    sxtw    x13, w13                // x13 = b_ax
    sxtw    x14, w14                // x14 = b_ay
    sxtw    x15, w15                // x15 = b_bx
    sxtw    x16, w16                // x16 = b_by

    // --- Quick exact-integer cross-product snap tests ---
    // Compute dax = a_bx - a_ax (x17), day = a_by - a_ay (x30? No, use x9/x10/x11/x17):
    // First save b_min_x (w9), b_min_y (w10), b_max_y (w11), b_meta (w12) — we can reload from [x28] if needed.
    sub     x9, x22, x20            // x9  = dax = a_bx - a_ax
    sub     x10, x23, x21           // x10 = day = a_by - a_ay
    cmp     x9, #0
    cneg    x11, x9, lt             // |dax|
    cmp     x10, #0
    cneg    x17, x10, lt            // |day|
    add     x11, x11, x17           // x11 = adax + aday

    // Test 1: snap b_a (x13, x14) onto sa
    cmp     x13, x20
    ccmp    x14, x21, #0, eq
    b.eq    L_vs_snap2
    cmp     x13, x22
    ccmp    x14, x23, #0, eq
    b.eq    L_vs_snap2
    // Check widened bbox of sa for (b_ax, b_ay):
    ldr     w17, [x19, #0]          // a.min_x
    sxtw    x17, w17
    sub     x17, x17, #1
    cmp     x13, x17
    b.lt    L_vs_snap2
    sxtw    x17, w25                // sa_max_x_1
    cmp     x13, x17
    b.gt    L_vs_snap2
    sxtw    x17, w26                // sa_min_y_1
    cmp     x14, x17
    b.lt    L_vs_snap2
    sxtw    x17, w27                // sa_max_y_1
    cmp     x14, x17
    b.gt    L_vs_snap2
    // cross = (b_ax - a_ax)*day - (b_ay - a_ay)*dax
    sub     x17, x13, x20
    mul     x17, x17, x10
    sub     x12, x14, x21
    msub    x17, x12, x9, x17       // x17 = cross
    cmp     x17, #0
    cneg    x17, x17, lt
    lsl     x17, x17, #1            // 2 * |cross|
    cmp     x17, x11                // <= adax + aday ?
    b.le    L_vs_emit

L_vs_snap2:
    // Test 2: snap b_b (x15, x16) onto sa
    cmp     x15, x20
    ccmp    x16, x21, #0, eq
    b.eq    L_vs_snap3
    cmp     x15, x22
    ccmp    x16, x23, #0, eq
    b.eq    L_vs_snap3
    ldr     w17, [x19, #0]
    sxtw    x17, w17
    sub     x17, x17, #1
    cmp     x15, x17
    b.lt    L_vs_snap3
    sxtw    x17, w25
    cmp     x15, x17
    b.gt    L_vs_snap3
    sxtw    x17, w26
    cmp     x16, x17
    b.lt    L_vs_snap3
    sxtw    x17, w27
    cmp     x16, x17
    b.gt    L_vs_snap3
    sub     x17, x15, x20
    mul     x17, x17, x10
    sub     x12, x16, x21
    msub    x17, x12, x9, x17
    cmp     x17, #0
    cneg    x17, x17, lt
    lsl     x17, x17, #1
    cmp     x17, x11
    b.le    L_vs_emit

L_vs_snap3:
    // Compute dbx = b_bx - b_ax (x11), dby = b_by - b_ay (x12)
    // and adbx + adby in x17? Keep x9=dax, x10=day!
    sub     x11, x15, x13           // x11 = dbx
    sub     x12, x16, x14           // x12 = dby

    // Test 3: snap a_a (x20, x21) onto sb
    cmp     x20, x13
    ccmp    x21, x14, #0, eq
    b.eq    L_vs_snap4
    cmp     x20, x15
    ccmp    x21, x16, #0, eq
    b.eq    L_vs_snap4
    // Quick cross-product check first (faster than 4 bbox loads since most fail cross!):
    sub     x17, x20, x13
    mul     x17, x17, x12
    sub     x9, x21, x14
    msub    x17, x9, x11, x17       // cross
    cmp     x17, #0
    cneg    x17, x17, lt
    lsl     x17, x17, #1
    cmp     x11, #0
    cneg    x9, x11, lt
    cmp     x12, #0
    cneg    x10, x12, lt
    add     x9, x9, x10             // adbx + adby
    cmp     x17, x9
    b.gt    L_vs_snap4
    // Also verify widened bbox of sb:
    ldp     w9, w10, [x28, #0]      // b.min_x, b.min_y
    sxtw    x9, w9
    sub     x9, x9, #1
    cmp     x20, x9
    b.lt    L_vs_snap4
    cmp     x13, x15
    csel    x9, x13, x15, ge        // b_max_x
    add     x9, x9, #1
    cmp     x20, x9
    b.gt    L_vs_snap4
    sxtw    x10, w10
    sub     x10, x10, #1
    cmp     x21, x10
    b.lt    L_vs_snap4
    ldr     w10, [x28, #8]          // b.max_y
    sxtw    x10, w10
    add     x10, x10, #1
    cmp     x21, x10
    b.le    L_vs_emit

L_vs_snap4:
    // Test 4: snap a_b (x22, x23) onto sb
    cmp     x22, x13
    ccmp    x23, x14, #0, eq
    b.eq    L_vs_isect
    cmp     x22, x15
    ccmp    x23, x16, #0, eq
    b.eq    L_vs_isect
    sub     x17, x22, x13
    mul     x17, x17, x12
    sub     x9, x23, x14
    msub    x17, x9, x11, x17       // cross
    cmp     x17, #0
    cneg    x17, x17, lt
    lsl     x17, x17, #1
    cmp     x11, #0
    cneg    x9, x11, lt
    cmp     x12, #0
    cneg    x10, x12, lt
    add     x9, x9, x10             // adbx + adby
    cmp     x17, x9
    b.gt    L_vs_isect
    ldp     w9, w10, [x28, #0]
    sxtw    x9, w9
    sub     x9, x9, #1
    cmp     x22, x9
    b.lt    L_vs_isect
    cmp     x13, x15
    csel    x9, x13, x15, ge
    add     x9, x9, #1
    cmp     x22, x9
    b.gt    L_vs_isect
    sxtw    x10, w10
    sub     x10, x10, #1
    cmp     x23, x10
    b.lt    L_vs_isect
    ldr     w10, [x28, #8]
    sxtw    x10, w10
    add     x10, x10, #1
    cmp     x23, x10
    b.le    L_vs_emit

L_vs_isect:
    // Exact bbox check: b_min_x <= a_max_x && b_max_y >= a_min_y && b_min_y <= a_max_y
    ldp     w9, w10, [x28, #0]      // b.min_x, b.min_y
    sxtw    x9, w9
    cmp     x9, x24                 // b.min_x > a_max_x ?
    b.gt    L_vs_next_aj
    ldr     w9, [x28, #8]           // b.max_y
    add     w17, w26, #1            // a.min_y = sa_min_y_1 + 1
    cmp     w9, w17
    b.lt    L_vs_next_aj
    sub     w17, w27, #1            // a.max_y = sa_max_y_1 - 1
    cmp     w10, w17
    b.gt    L_vs_next_aj

    // skip_same_set check:
    cbz     x3, L_vs_do_isect
    ldr     w10, [x28, #28]         // b.meta
    ubfx    x9, x25, #62, #1        // i_clip
    ubfx    x10, x10, #30, #1       // j_clip
    cmp     x9, x10
    b.eq    L_vs_next_aj

L_vs_do_isect:
    // Recompute dax (x9), day (x10); x11=dbx, x12=dby already live!
    sub     x9, x22, x20            // dax
    sub     x10, x23, x21           // day

    // denom = dax*dby - day*dbx (x17)
    mul     x17, x9, x12
    msub    x17, x10, x11, x17
    cbz     x17, L_vs_collinear

    // Check shared endpoint: if shared, skip proper intersection (cannot be collinear since denom != 0!)
    cmp     x20, x13
    ccmp    x21, x14, #0, eq
    b.eq    L_vs_next_aj
    cmp     x20, x15
    ccmp    x21, x16, #0, eq
    b.eq    L_vs_next_aj
    cmp     x22, x13
    ccmp    x23, x14, #0, eq
    b.eq    L_vs_next_aj
    cmp     x22, x15
    ccmp    x23, x16, #0, eq
    b.eq    L_vs_next_aj

    // Proper intersection test:
    // rx = b_ax - a_ax (x13-x20), ry = b_ay - a_ay (x14-x21)
    sub     x13, x13, x20           // rx
    sub     x14, x14, x21           // ry
    mul     x15, x13, x12
    msub    x15, x14, x11, x15      // num_a = rx*dby - ry*dbx
    mul     x16, x13, x10
    msub    x16, x14, x9, x16       // num_b = rx*day - ry*dax

    // If denom < 0, negate denom, num_a, num_b so we only check 0 <= num <= denom!
    cmp     x17, #0
    b.gt    L_vs_check_pos
    neg     x17, x17
    neg     x15, x15
    neg     x16, x16
L_vs_check_pos:
    cmp     x15, x17                // unsigned compare: 0 <= num_a <= denom iff (u64)num_a <= (u64)denom!
    b.hi    L_vs_next_aj
    cmp     x16, x17
    b.ls    L_vs_emit
    b       L_vs_next_aj

L_vs_collinear:
    // denom == 0: check dax*(b_ay - a_ay) - day*(b_ax - a_ax) == 0
    sub     x14, x14, x21           // b_ay - a_ay
    sub     x13, x13, x20           // b_ax - a_ax
    mul     x17, x9, x14
    msub    x17, x10, x13, x17
    cbnz    x17, L_vs_next_aj
    // Also check dax*(b_by - a_ay) - day*(b_bx - a_ax) == 0
    sub     x16, x16, x21
    sub     x15, x15, x20
    mul     x17, x9, x16
    msub    x17, x10, x15, x17
    cbnz    x17, L_vs_next_aj
    // Collinear overlap! Emit!

L_vs_emit:
    cmp     x6, x5
    b.ge    L_vs_overflow
    orr     x17, x7, x8, lsl #32    // pack ai | (aj << 32)
    str     x17, [x4, x6, lsl #3]
    add     x6, x6, #1

L_vs_next_aj:
    add     x8, x8, #1
    add     x28, x28, #32
    cmp     x8, x1
    b.lt    L_vs_aj_loop

L_vs_next_ai:
    add     x7, x7, #1
    add     x19, x19, #32
    b       L_vs_ai_loop

L_vs_overflow:
    mov     x0, #-1
    b       L_vs_ret

L_vs_done:
    mov     x0, x6

L_vs_ret:
    ldp     x27, x28, [sp, #80]
    ldp     x25, x26, [sp, #64]
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #96
    ret


// ============================================================================
// _hw_vatti_snap_strip_pass2
//
// Hand-written ARM64 collinear-overlap filter for `vatti_snap_round` Pass 2.
// Scans all pairs (ai < aj) in `st[0..n_st]` (32-byte RStrip_Entry structs)
// and emits `(ai | (aj << 32))` ONLY for collinear overlapping pairs (<1%).
//
// RStrip_Entry layout (32 bytes, identical to Strip_Entry):
//   +0  min_x: i32
//   +4  min_y: i32
//   +8  max_y: i32
//   +12 ax:    i32
//   +16 ay:    i32
//   +20 bx:    i32
//   +24 by:    i32
//   +28 meta:  u32  (idx:24 | s0:6 << 24)
//
// Signature:
//   i64 hw_vatti_snap_strip_pass2(
//       const RStrip_Entry *st,  // x0
//       i64 n_st,                // x1
//       u64 s_u32,               // x2
//       u64 *out_pairs,          // x3
//       i64 out_cap              // x4
//   )
// Returns:
//   number of emitted pairs (>= 0), or -1 if out_pairs overflowed.
// ============================================================================
.p2align 4
.globl _hw_vatti_snap_strip_pass2
_hw_vatti_snap_strip_pass2:
    stp     x29, x30, [sp, #-80]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]

    mov     x5, #0                  // out_count = 0
    cmp     x1, #2
    b.lt    L_p2_done

    mov     x6, #0                  // ai = 0
    mov     x19, x0                 // ptr_i = &st[0]

.p2align 4
L_p2_ai_loop:
    add     x7, x6, #1              // aj = ai + 1
    cmp     x7, x1
    b.ge    L_p2_done

    ldp     w8, w9, [x19, #4]       // w8 = a.min_y, w9 = a.max_y
    ldp     w10, w11, [x19, #12]    // w10 = a.ax,   w11 = a.ay
    ldp     w12, w13, [x19, #20]    // w12 = a.bx,   w13 = a.by
    ldr     w14, [x19, #28]         // w14 = a.meta

    sxtw    x20, w10                // x20 = a_ax
    sxtw    x21, w11                // x21 = a_ay
    sxtw    x12, w12                // x12 = a_bx
    sxtw    x13, w13                // x13 = a_by
    sub     x22, x12, x20           // x22 = dax
    sub     x23, x13, x21           // x23 = day

    cmp     w10, w12
    csel    w24, w10, w12, ge       // w24 = a_max_x (i32)
    ubfx    x25, x14, #24, #6       // x25 = i_s0
    add     x26, x19, #32           // ptr_j = ptr_i + 32

.p2align 4
L_p2_aj_loop:
    ldr     w10, [x26, #0]          // b.min_x
    cmp     w10, w24                // b.min_x > a_max_x ?
    b.gt    L_p2_next_ai
    ldp     w11, w12, [x26, #4]     // b.min_y, b.max_y
    cmp     w12, w8                 // b.max_y < a_min_y ?
    b.lt    L_p2_next_aj
    cmp     w11, w9                 // b.min_y > a_max_y ?
    b.gt    L_p2_next_aj

    ldr     w13, [x26, #28]         // b.meta
    ubfx    x13, x13, #24, #6       // j_s0
    cmp     x25, x13
    csel    x13, x25, x13, ge       // max(i_s0, j_s0)
    cmp     x13, x2
    b.ne    L_p2_next_aj

    // Collinearity check 1: dax*(b_ay - a_ay) - day*(b_ax - a_ax) == 0
    ldp     w10, w11, [x26, #12]    // b.ax, b.ay
    sxtw    x10, w10
    sxtw    x11, w11
    sub     x10, x10, x20           // b_ax - a_ax
    sub     x11, x11, x21           // b_ay - a_ay
    mul     x14, x22, x11
    msub    x14, x23, x10, x14
    cbnz    x14, L_p2_next_aj

    // Collinearity check 2: dax*(b_by - a_ay) - day*(b_bx - a_ax) == 0
    ldp     w10, w11, [x26, #20]    // b.bx, b.by
    sxtw    x10, w10
    sxtw    x11, w11
    sub     x10, x10, x20           // b_bx - a_ax
    sub     x11, x11, x21           // b_by - a_ay
    mul     x14, x22, x11
    msub    x14, x23, x10, x14
    cbnz    x14, L_p2_next_aj

    // Collinear overlap! Emit (ai | (aj << 32))
    cmp     x5, x4
    b.ge    L_p2_overflow
    orr     x14, x6, x7, lsl #32
    str     x14, [x3, x5, lsl #3]
    add     x5, x5, #1

L_p2_next_aj:
    add     x7, x7, #1
    add     x26, x26, #32
    cmp     x7, x1
    b.lt    L_p2_aj_loop

L_p2_next_ai:
    add     x6, x6, #1
    add     x19, x19, #32
    b       L_p2_ai_loop

L_p2_overflow:
    mov     x0, #-1
    b       L_p2_ret

L_p2_done:
    mov     x0, x5

L_p2_ret:
    ldp     x25, x26, [sp, #64]
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #80
    ret
