# COPYREG_NOTES — i32-pointer ↔ i64-register boundary on powerpc64-scei-lv2

Branch: `ppc-lv2-abi`. Build: `llvm-project/build` (Ninja, Release, assertions ON).
Probe driver: `clang -target powerpc64-scei-lv2 -ffreestanding -fno-pic -mcpu=ppc64 -O2 -c <probe>.c`

## Phase -1 — REAL baseline (recorded BEFORE any code change)

Canonical probe set is `probes/probe1.c`, `probes/probe2.c`, `probes/probe3.c` (created
verbatim from the task spec). The stale `probes/ps3_abi_probe*.c` files were deleted so there
is one definitive test set.

| probe | result | exact cause |
|-------|--------|-------------|
| probe1 (indirect call) | **FAIL** | `report_fatal_error("Impossible reg-to-reg copy")` at `PPCInstrInfo.cpp:1911`, in `Post-RA pseudo instruction expansion` on `@dispatch`. A bare GPRC→G8RC `COPY` (the 32-bit callee pointer entering the 64-bit CTR). |
| probe2 (leaf + ptrs in static data) | **PASS** (exit 0) | No pointer ever lives in a register at runtime; OPD emission + the fn-ptr OPD reloc work. |
| probe3 (bare global load) | **FAIL** | Identical `Impossible reg-to-reg copy` at `PPCInstrInfo.cpp:1911`, in Post-RA pseudo expansion on `@load_g`. Same bare GPRC→G8RC `COPY` (the i32 global address becoming the 64-bit base of the load). |

**OPD status:** probe2 PASSES, so OPD emission + the function-pointer OPD relocation are
sound. The two failures are NOT an OPD problem — both are the single GPRC↔G8RC copy gap.

**`lv2-opd.ll` determination (the red test):** the `.opd` descriptor itself is emitted
**correctly** — `.section .opd`, label, `.p2align 2`, `.long .Lfunc_begin0`, `.long
.TOC.@tocbase`, no env word, then a section switch back to `.text` (matches CHECK lines
20-24). The test fails only because its two trailing checks, `CHECK-NOT: .quad` and
`CHECK-NOT: .long 0`, are **unanchored** and accidentally match the standard PPC64 traceback
end-marker (`.long 0` + `.quad 0`) that `PPCLinuxAsmPrinter::emitFunctionBodyEnd`
(`PPCAsmPrinter.cpp:2244`) emits after `blr` for **every** `isPPC64()` function. The
`powerpc64-unknown-linux-gnu` ELFv1 reference emits the byte-identical `.long 0` + `.quad 0`
there, so this is shared upstream behaviour, **not** an Lv2 OPD regression. **Verdict: bad
test (scoping bug), not an OPD codegen regression.** Fix = scope the negative checks to the
`.opd` section (assert the descriptor is exactly two words by `CHECK-NEXT: .text` after the
TOC word) instead of the global unanchored `CHECK-NOT`. The OPD emission code is NOT touched.

All later "no new failures" gates are measured against THIS baseline.

## Phase 0 — diagnosis of the GPRC↔G8RC copy (probe3, the minimal repro)

`-stop-after=finalize-isel` MIR for `@load_g`:

```
%0:g8rc_and_g8rc_nox0 = ADDIStocHA8 $x2, @g
%1:g8rc              = LDtocL @g, killed %0   ; (load (s64) from got) — full 64-bit address
%2:gprc              = COPY %1.sub_32         ; TRUNCATE to i32 (the 32-bit pointer)
%4:g8rc_nox0         = COPY %2                ; RE-WIDEN i32→i64 for the load base  <-- CRASH
%3:g8rc              = LWA 0, killed %4        ; (load (s32) from @g)
$x3 = COPY %3
BLR8 ...
```

### Finding 1 — origin of the i32 value
The selected DAG (`-debug-only=isel`) is:
```
t12: i64 = PPCISD::TOC_ENTRY<(load (s64) from got)> TGA<@g>, $x2      ; full i64 address
t13: i32 = truncate t12   -> EXTRACT_SUBREG t12, sub_32              ; the i32 pointer
t9 : i64 = LWA 0, t13                                                ; LWA base wants g8rc_nox0
```
Path: `LowerGlobalAddress` (PPCISelLowering.cpp:3560) → `is64BitELFABI()` →
`getTOCEntry` (PPCISelLowering.cpp:3050). **`getTOCEntry` loads the TOC slot as `VT`
(i64 on PPC64) and then, because the GlobalAddress node type is i32 (datalayout `p:32:32`),
emits `ISD::TRUNCATE` to i32 at line 3068.** That is the confirmed origin of the gprc value
— exactly the suspect in the task. `t13` (the truncate) is then used directly as the **base
operand of `LWA`**, whose operand register class is `g8rc_nox0`. The i32(gprc)→i64(g8rc)
operand-class mismatch is bridged by **InstrEmitter** with a bare `COPY` (`%4 = COPY %2`),
which `copyPhysReg` cannot lower → fatal error.

This is NOT specific to TOC addresses: because `p:32:32` makes *every* pointer SDValue i32,
*every* memory access / CTR call on Lv2 feeds an i32 base into a 64-bit base operand, so
InstrEmitter inserts a GPRC→G8RC `COPY` at each such site. `copyPhysReg` is therefore the
single universal choke point where this conversion is realised. (probe1 hits the same gap via
`MTCTR8`/the 64-bit CTR.)

### Finding 2 — extension invariant
PS3 GameOS user addresses are < 4 GB (ground-truth ABI: pointers fit in 32 bits,
zero-extended into the 64-bit GPR; the OPD TOC word is a 32-bit value zero-extended into r2).
**The widening GPRC→G8RC must be a ZERO-extend** (`clrldi`/`RLDICL …,0,32`), not a sign-extend.
The narrowing G8RC→GPRC is a plain low-32 read (`sub_32`). This matches the x32/n32 model and
PPCInstr64Bit.td:1871's canonical i32→i64 zero-extend
(`RLDICL (INSERT_SUBREG IMPLICIT_DEF, $in, sub_32), 0, 32`).

### Finding 3 — TOC entry size (latent BE bug — recorded for follow-up, NOT fixed here)
`getTOCEntry` currently emits a **64-bit** load of the TOC slot (`LDtocL`, "load (s64) from
got") then truncates. On big-endian, if the real PS3 TOC/GOT slot for a 32-bit pointer is only
**4 bytes**, a 64-bit load reads this slot's 4 bytes plus the *next* slot's 4 bytes, and the
low-32 truncate then returns the WRONG (next) slot — `LDtocL` itself would be wrong,
independent of the copy bug.

Reference binary `reference-binaries/vsh/vsh.elf`: EI_OSABI 0x66, EXEC, BE, ELF64; section
names are stripped. Entry OPD `{code=0x00010230, rtoc=0x006f5558}` → module TOC base r2 =
0x006f5558. The data around r2 looks like packed 32-bit small-data records, not a clean
8-byte pointer GOT, so the slot stride cannot be settled from the stripped binary without the
real SN/GCC PS3 toolchain. rpcs3 confirms pointer relocations are R_PPC64_ADDR32 (4-byte) and
`ppu_func_opd_t` is two 32-bit words.

**Decision:** the slot-stride / load-width question is **orthogonal to the copy bug** (the
GPRC↔G8RC crash exists regardless of load width) and is explicitly a "record for follow-up"
item. It is NOT fixed in this change. Importantly, the chosen fix is **value-correct for
either stride**: the GPRC→G8RC widening is an explicit **zero-extend of the low 32 bits**, so
it yields the correct < 4 GB base whether or not the high half of the LDtocL result happens to
be zero. (A "reuse the i64 directly / drop the truncate" fix would instead depend on the high
half being zero, i.e. on an 8-byte zero-extended slot — so it is deliberately avoided until
the stride is confirmed.)

## Phase 1 — the fix (see commit)
Backstop in `PPCInstrInfo::copyPhysReg`, **gated strictly on `Subtarget.isLv2ABI()`** so every
other PPC subtarget is byte-for-byte unchanged:
- **GPRC→G8RC**: zero-extend — `RLDICL DestG8, superreg(Src), 0, 32` (= `clrldi …,32`).
- **G8RC→GPRC**: low-32 read — `OR DestGPR, subreg(Src,sub_32), subreg(Src,sub_32)`.

These bare cross-class copies are inherent to ILP32-on-PPC64 (i32 datalayout pointers) and
never arise on other subtargets, so `copyPhysReg` is the correct universal realization point;
the gate guarantees no non-Lv2 path changes. FastISel: the probes use `-O2` (FastISel is an
`-O0` path); the `-O0` behaviour is checked separately in the verification step and recorded
in the final report.
