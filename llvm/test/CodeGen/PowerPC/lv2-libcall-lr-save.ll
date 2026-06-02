; PS3/Lv2 (ILP32-on-PPC64): a compiler-emitted libcall (memcpy/memset/...) has an
; ExternalSymbol (i32 texternalsym) callee. It must select the 64-bit BL8_NOP
; (which clobbers $lr8) so a non-leaf caller saves/restores LR; otherwise it falls
; to the generic 32-bit BL_NOP (clobbers $lr, not $lr8), LR is never saved, and the
; caller's `blr` returns into its own epilogue (r1 runs off the stack). Companion to
; the tglobaladdr fix (lv2-direct-call / commit c31c035) for the libcall path.

; RUN: llc -mtriple=powerpc64-scei-lv2 -mcpu=ppc64 < %s | FileCheck %s --check-prefix=LV2
; RUN: llc -mtriple=powerpc64-unknown-linux-gnu -mcpu=ppc64 < %s | FileCheck %s --check-prefix=PPC64

; A variable-length llvm.memcpy lowers to a `memcpy` libcall (ExternalSymbol). f is
; non-leaf, so it must save/restore LR around the call.
define void @f(ptr %d, ptr %s, i32 %n) {
entry:
  call void @llvm.memcpy.p0.p0.i32(ptr %d, ptr %s, i32 %n, i1 false)
  ret void
}

declare void @llvm.memcpy.p0.p0.i32(ptr, ptr, i32, i1)

; LV2: f:
; LV2:   mflr 0
; LV2:   bl .memcpy
; LV2:   mtlr 0
; LV2:   blr

; PPC64: f:
; PPC64:   mflr 0
; PPC64:   bl memcpy
; PPC64:   mtlr 0
; PPC64:   blr
