; PS3 GameOS (Cell OS Lv-2) is ILP32-on-PPC64: pointers are i32 (GPRC) but every
; memory base must be a 64-bit G8RC register. Verify the i32-address -> 64-bit-base
; conversion selects cleanly as an explicit ZERO-extend (clrldi rD, rS, 32) -- PS3
; user addresses are < 4 GB -- instead of crashing in copyPhysReg with
; "Impossible reg-to-reg copy". Each RUN uses its target's default datalayout
; (no explicit datalayout line), so the non-Lv2 ppc64 run must be unchanged: a
; 64-bit pointer needs no widening and emits no clrldi.
;
; RUN: llc -verify-machineinstrs -mtriple=powerpc64-scei-lv2 \
; RUN:     -mcpu=ppc64 -O2 < %s | FileCheck %s --check-prefix=LV2
; RUN: llc -verify-machineinstrs -mtriple=powerpc64-unknown-linux-gnu \
; RUN:     -mcpu=ppc64 -O2 < %s | FileCheck %s --check-prefix=NOLV2

@g = external global i32

define i32 @load_g() {
entry:
  %v = load i32, ptr @g
  ret i32 %v
}

; The TOC slot is loaded (ld), the i32 address is zero-extended into the 64-bit
; base (clrldi ..., 32), then dereferenced. clrldi is RLDICL rD, rS, 0, 32.
; LV2-LABEL: load_g:
; LV2:         ld [[ADDR:[0-9]+]], .LC0@toc@l([[ADDR]])
; LV2-NEXT:    clrldi [[ADDR]], [[ADDR]], 32
; LV2-NEXT:    lwz {{[0-9]+}}, 0([[ADDR]])
; LV2-NEXT:    blr

; Non-Lv2 ppc64: pointer is already 64-bit, so NO widening is inserted.
; NOLV2-LABEL: load_g:
; NOLV2:         ld [[ADDR:[0-9]+]], .LC0@toc@l([[ADDR]])
; NOLV2-NEXT:    lwz {{[0-9]+}}, 0([[ADDR]])
; NOLV2-NEXT:    blr
; NOLV2-NOT:     clrldi

define void @store_g(i32 %x) {
entry:
  store i32 %x, ptr @g
  ret void
}

; The store base is widened the same explicit way on Lv2 ...
; LV2-LABEL: store_g:
; LV2:         clrldi [[SADDR:[0-9]+]], [[SADDR]], 32
; LV2-NEXT:    stw {{[0-9]+}}, 0([[SADDR]])
; LV2-NEXT:    blr

; ... and not at all on non-Lv2 ppc64.
; NOLV2-LABEL: store_g:
; NOLV2-NOT:     clrldi
