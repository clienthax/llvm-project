; PS3 GameOS (Cell OS Lv-2) is ILP32-on-PPC64: pointers are i32 and the TOC is a
; ppc32-style .got2 with 4-byte pointer slots. Verify two things:
;  (1) the 4-byte TOC slot is read with a 32-bit zero-extending lwz, NOT a 64-bit
;      ld -- on big-endian a 64-bit load of a 4-byte slot straddles into the
;      adjacent slot and returns the wrong pointer;
;  (2) the i32 address still becomes a 64-bit base cleanly (no copyPhysReg crash).
; Each RUN uses its target's default datalayout (no explicit datalayout line), so
; the non-Lv2 ppc64 run must be unchanged: an 8-byte .toc slot read with ld.
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

; Lv2: TOC-high via addis, then the 4-byte slot via a 32-bit lwz (the fix), then
; the i32 address widened to a 64-bit base and dereferenced.
; LV2-LABEL: load_g:
; LV2:         addis [[HI:[0-9]+]], 2, .LC0@toc@ha
; LV2-NEXT:    lwz [[ADDR:[0-9]+]], .LC0@toc@l([[HI]])
; LV2-NEXT:    clrldi {{[0-9]+}}, {{[0-9]+}}, 32
; LV2-NEXT:    lwz {{[0-9]+}}, 0({{[0-9]+}})
; LV2-NEXT:    blr
; The TOC slot must NOT be read with a 64-bit ld on Lv2.
; LV2-NOT:     ld {{[0-9]+}}, .LC{{[0-9]+}}@toc@l

; Non-Lv2 ppc64: 8-byte .toc slot, read with a 64-bit ld; pointer is already
; 64-bit so there is no widening (no clrldi).
; NOLV2-LABEL: load_g:
; NOLV2:         ld [[ADDR:[0-9]+]], .LC0@toc@l([[ADDR]])
; NOLV2-NEXT:    lwz {{[0-9]+}}, 0([[ADDR]])
; NOLV2-NEXT:    blr
; NOLV2-NOT:     clrldi
