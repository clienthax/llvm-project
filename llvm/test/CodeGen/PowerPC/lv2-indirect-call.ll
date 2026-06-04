; Indirect-call TOC restore on the PS3/Lv2 ABI (powerpc64-scei-lv2, ILP32 on
; PPC64). The TOC save slot is the constant r1+40, so an indirect call must
; select the dedicated hardcoded form BCTRL8_LDinto_toc_lv2, whose asm is the
; literal "bctrl ; ld 2, 40(1)" with no address operand -- mirroring AIX's
; BL8_LDinto_toc. A standard ppc64 ELFv1 target must be unchanged and still
; select the memrix BCTRL8_LDinto_toc.
;
; The test stops after instruction selection: selecting the operand-less Lv2
; node is exactly the behavior under test (the restore address is baked into
; the instruction). End-to-end asm emission for any Lv2 indirect call is
; currently blocked by a separate, pre-existing Lv2 codegen gap unrelated to
; the TOC restore -- PPCInstrInfo::copyPhysReg cannot lower the GPRC->G8RC copy
; that places a 32-bit callee pointer into the 64-bit CTR.

; RUN: llc -mtriple=powerpc64-scei-lv2 -mcpu=ppc64 -stop-after=finalize-isel < %s \
; RUN:   | FileCheck %s --check-prefix=LV2
; RUN: llc -mtriple=powerpc64-unknown-linux-gnu -mcpu=ppc64 -stop-after=finalize-isel < %s \
; RUN:   | FileCheck %s --check-prefix=ELFV1

define void @call_via_ptr(ptr %fp) {
entry:
  call void %fp()
  ret void
}

; Lv2 selects the hardcoded operand-less restore (RST=2/RA=1/D=40 baked in).
; LV2-LABEL: name: call_via_ptr
; LV2: BCTRL8_LDinto_toc_lv2
; LV2-NOT: BCTRL8_LDinto_toc{{[ ]}}

; Non-Lv2 ppc64 ELFv1 is unchanged: the restore address arrives via the memrix
; operand (40, $x1) on the shared BCTRL8_LDinto_toc.
; ELFV1-LABEL: name: call_via_ptr
; ELFV1: BCTRL8_LDinto_toc 40, $x1
; ELFV1-NOT: BCTRL8_LDinto_toc_lv2
