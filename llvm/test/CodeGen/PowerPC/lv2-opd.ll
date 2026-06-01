; Verify the PS3 GameOS (Cell OS Lv-2) compact function descriptor (.opd) is
; emitted as two 4-byte words {code_entry, .TOC.}, 4-byte aligned, with no
; environment word -- unlike the 24-byte ppc64 ELFv1 descriptor. The toc word
; is a plain (R_PPC64_ADDR32) reference to .TOC. that binutils ld resolves at a
; 4-byte field, NOT the doubleword R_PPC64_TOC (.TOC.@tocbase) form.
; RUN: llc -verify-machineinstrs -mtriple=powerpc64-scei-lv2 \
; RUN:     -mcpu=ppc64 -O2 < %s | FileCheck %s

; The toc word lowers to R_PPC64_ADDR32 against .TOC. (the .opd code word stays
; R_PPC64_ADDR32 against .text); no R_PPC64_TOC in the Lv2 object.
; RUN: llc -verify-machineinstrs -mtriple=powerpc64-scei-lv2 \
; RUN:     -mcpu=ppc64 -O2 -filetype=obj < %s | llvm-readobj -r - \
; RUN:     | FileCheck %s --check-prefix=RELOC

; Sanity: the standard ppc64 ELFv1 descriptor is still 3 doublewords.
; RUN: llc -verify-machineinstrs -mtriple=powerpc64-unknown-linux-gnu \
; RUN:     -mcpu=ppc64 -O2 < %s | FileCheck %s --check-prefix=ELFV1

; The standard ELFv1 toc word stays R_PPC64_TOC (8-byte doubleword form).
; RUN: llc -verify-machineinstrs -mtriple=powerpc64-unknown-linux-gnu \
; RUN:     -mcpu=ppc64 -O2 -filetype=obj < %s | llvm-readobj -r - \
; RUN:     | FileCheck %s --check-prefix=ELFV1RELOC

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
; CHECK-NEXT: .long .TOC.
; CHECK-NEXT: .text

; RELOC:      Section{{.*}}.rela.opd {
; RELOC-NEXT:   R_PPC64_ADDR32 .text
; RELOC-NEXT:   R_PPC64_ADDR32 .TOC.
; RELOC-NEXT: }

; ELFV1:      .section .opd,"aw",@progbits
; ELFV1-NEXT: leaf:
; ELFV1-NEXT: .p2align 3
; ELFV1-NEXT: .quad .Lfunc_begin0
; ELFV1-NEXT: .quad .TOC.@tocbase
; ELFV1-NEXT: .quad 0

; ELFV1RELOC:      Section{{.*}}.rela.opd {
; ELFV1RELOC-NEXT:   R_PPC64_ADDR64 .text
; ELFV1RELOC-NEXT:   R_PPC64_TOC -
; ELFV1RELOC-NEXT: }
