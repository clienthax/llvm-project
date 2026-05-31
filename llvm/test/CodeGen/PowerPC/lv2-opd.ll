; Verify the PS3 GameOS (Cell OS Lv-2) compact function descriptor (.opd) is
; emitted as two 4-byte words {code_entry, .TOC.@tocbase}, 4-byte aligned, with
; no environment word -- unlike the 24-byte ppc64 ELFv1 descriptor.
; RUN: llc -verify-machineinstrs -mtriple=powerpc64-scei-lv2 \
; RUN:     -mcpu=ppc64 -O2 < %s | FileCheck %s

; Sanity: the standard ppc64 ELFv1 descriptor is still 3 doublewords.
; RUN: llc -verify-machineinstrs -mtriple=powerpc64-unknown-linux-gnu \
; RUN:     -mcpu=ppc64 -O2 < %s | FileCheck %s --check-prefix=ELFV1

target datalayout = "E-m:e-p:32:32-Fi64-i64:64-i128:128-n32:64"
target triple = "powerpc64-scei-lv2"

define i32 @leaf(i32 %a, i32 %b) {
entry:
  %add = add nsw i32 %a, %b
  ret i32 %add
}

; The compact descriptor is exactly two 4-byte words: code entry then TOC base,
; immediately followed by the switch back to .text -- no third (environment)
; word and no .quad. (Anchor on .text rather than an unscoped CHECK-NOT, which
; would spuriously match the standard PPC64 traceback marker `.long 0`/`.quad 0`
; that emitFunctionBodyEnd emits inside .text for every ppc64 function.)
; CHECK:      .section .opd,"aw",@progbits
; CHECK-NEXT: leaf:
; CHECK-NEXT: .p2align 2
; CHECK-NEXT: .long .Lfunc_begin0
; CHECK-NEXT: .long .TOC.@tocbase
; CHECK-NEXT: .text

; ELFV1:      .section .opd,"aw",@progbits
; ELFV1-NEXT: leaf:
; ELFV1-NEXT: .p2align 3
; ELFV1-NEXT: .quad .Lfunc_begin0
; ELFV1-NEXT: .quad .TOC.@tocbase
; ELFV1-NEXT: .quad 0
