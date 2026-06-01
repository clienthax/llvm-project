; Direct-call selection on the PS3/Lv2 ABI (powerpc64-scei-lv2, ILP32 on PPC64).
; A direct call to a function whose definition is external at compile time emits
; PPCISD::CALL_NOP with an i32 (ILP32) TargetGlobalAddress callee. The i64
; BL8_NOP patterns need an i64 callee and the i32 texternalsym/mcsym call_nop
; patterns don't cover an i32 tglobaladdr, so without the Lv2-gated
; (PPCcall_nop (i32 tglobaladdr)) -> BL8_NOP pattern this is "Cannot select".
;
; The emitted sequence is the standard ELFv1 `bl` + `nop`: for a local
; intra-module callee the linker leaves the nop and r2 is preserved (no
; caller-side TOC save is done for direct calls; only the indirect path
; saves/restores r2 because it clobbers r2 with the descriptor's TOC). A standard
; ppc64 ELFv1 target must be byte-for-byte unchanged.

; RUN: llc -verify-machineinstrs -mtriple=powerpc64-scei-lv2 -mcpu=ppc64 -O2 < %s \
; RUN:   | FileCheck %s --check-prefix=LV2
; RUN: llc -verify-machineinstrs -mtriple=powerpc64-unknown-linux-gnu -mcpu=ppc64 -O2 < %s \
; RUN:   | FileCheck %s --check-prefix=ELFV1

@sink = global i32 0, align 4

declare i32 @get_a()

; The store after the call keeps it out of tail position, so it lowers to a real
; call (CALL_NOP), and exercises a post-call TOC access (@sink via r2) that would
; be miscompiled if r2 were wrongly "restored" from an unsaved slot.
define void @call_it() {
entry:
  %v = call i32 @get_a()
  store volatile i32 %v, ptr @sink, align 4
  ret void
}

; Lv2: the direct call selects (no "Cannot select") and emits bl + nop; r2 is
; preserved across the call, so @sink is addressed off the live TOC (r2).
; LV2-LABEL: call_it:
; LV2:         bl get_a
; LV2-NEXT:    nop
; LV2:         addis {{[0-9]+}}, 2, {{[.A-Za-z0-9_]+}}@toc@ha

; Non-Lv2 ppc64 ELFv1 is unchanged: still the standard bl + nop.
; ELFV1-LABEL: call_it:
; ELFV1:         bl get_a
; ELFV1-NEXT:    nop
; ELFV1:         addis {{[0-9]+}}, 2, {{[.A-Za-z0-9_]+}}@toc@ha
