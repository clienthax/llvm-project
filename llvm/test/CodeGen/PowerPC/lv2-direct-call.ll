; Direct-call selection on the PS3/Lv2 ABI (powerpc64-scei-lv2, ILP32 on PPC64).
; A direct call to a function external at compile time emits PPCISD::CALL_NOP
; with an i32 (ILP32) TargetGlobalAddress callee. The i64 BL8_NOP patterns need
; an i64 callee and the i32 texternalsym/mcsym call_nop patterns don't cover an
; i32 tglobaladdr, so without the Lv2-gated (PPCcall_nop (i32 tglobaladdr)) ->
; BL8_NOP pattern this is "Cannot select".
;
; The emitted sequence is the standard ELFv1 `bl` + `nop`, but the branch targets
; the function's code-entry symbol ".foo" (MO_LV2_FUNC_ENTRY), NOT "foo" -- on
; Lv2 "foo" labels the compact .opd descriptor, and binutils' opd-optimize bl
; redirection (which standard ELFv1 relies on) is disabled for that descriptor,
; so the caller references the ".foo" code symbol directly (the ELFv1 dot-symbol
; convention). A defined function emits ".foo" at its .text entry alongside the
; unchanged "foo" descriptor. A standard ppc64 ELFv1 target must be unchanged.

; RUN: llc -verify-machineinstrs -mtriple=powerpc64-scei-lv2 -mcpu=ppc64 -O2 < %s \
; RUN:   | FileCheck %s --check-prefix=LV2
; RUN: llc -verify-machineinstrs -mtriple=powerpc64-unknown-linux-gnu -mcpu=ppc64 -O2 < %s \
; RUN:   | FileCheck %s --check-prefix=ELFV1

@sink = global i32 0, align 4

declare i32 @get_a()

; The store after the call keeps it out of tail position (a real CALL_NOP), and
; exercises a post-call TOC access (@sink via r2) that would be miscompiled if r2
; were wrongly "restored" from an unsaved slot.
define void @call_it() {
entry:
  %v = call i32 @get_a()
  store volatile i32 %v, ptr @sink, align 4
  ret void
}

; A defined function: emits the "leaf" .opd descriptor AND the global code-entry
; symbol ".leaf" at the .text entry.
define i32 @leaf() {
entry:
  ret i32 7
}

; Lv2: the direct call selects (no "Cannot select") and emits bl + nop targeting
; the code-entry symbol; r2 is preserved, so @sink is addressed off the TOC (r2).
; LV2-LABEL: call_it:
; LV2:         bl .get_a
; LV2-NEXT:    nop
; LV2:         addis {{[0-9]+}}, 2, {{[.A-Za-z0-9_]+}}@toc@ha

; The defined function emits its .opd descriptor under "leaf" and a global
; ".leaf" code-entry symbol at the .text entry.
; LV2:         .section .opd
; LV2:       leaf:
; LV2:         .text
; LV2:         .globl .leaf
; LV2:       .leaf:

; Non-Lv2 ppc64 ELFv1 is unchanged: bl to the bare symbol + nop (it relies on the
; linker's opd-optimize redirection), no dot-prefixed code-entry symbol.
; ELFV1-LABEL: call_it:
; ELFV1:         bl get_a
; ELFV1-NEXT:    nop
; ELFV1:         addis {{[0-9]+}}, 2, {{[.A-Za-z0-9_]+}}@toc@ha
; ELFV1-NOT:     .globl .leaf
