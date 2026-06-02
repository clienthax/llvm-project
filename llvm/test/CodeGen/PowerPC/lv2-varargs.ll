; PS3/Lv2 (ILP32-on-PPC64) varargs: the variadic register-save area must spill the
; FULL 64-bit GPRs with 8-byte `std` stores into 8-byte slots, matching clang's
; 8-byte / big-endian-right-adjusted va_arg walk (and the real PS3 .printf prologue).
; Before the fix the Lv2 path spilled PtrVT (i32) with 4-byte `stw`, so va_arg read
; garbage. The fix is Lv2-gated; standard powerpc64 (PtrVT == i64) is unchanged --
; it already used `std` -- which the PPC64 check below pins.

; RUN: llc -mtriple=powerpc64-scei-lv2 -mcpu=ppc64 < %s | FileCheck %s --check-prefix=LV2
; RUN: llc -mtriple=powerpc64-unknown-linux-gnu -mcpu=ppc64 < %s | FileCheck %s --check-prefix=PPC64

define void @f(i32 %n, ...) {
entry:
  %ap = alloca ptr
  call void @llvm.va_start.p0(ptr %ap)
  call void @llvm.va_end.p0(ptr %ap)
  ret void
}

declare void @llvm.va_start.p0(ptr)
declare void @llvm.va_end.p0(ptr)

; The variadic GPRs r4..r10 are spilled with 8-byte `std` into the parameter save
; area (8-byte slots), NOT a 4-byte `stw`. (r3 holds the fixed arg %n and is not
; spilled. The va_list pointer itself is stored with a 4-byte `stw` because it is a
; 32-bit pointer under ILP32 -- that store is expected and not checked here.)

; LV2:      std 4, 56(1)
; LV2:      std 5, 64(1)
; LV2:      std 10, 104(1)

; PPC64:    std 4, 56(1)
; PPC64:    std 10, 104(1)
