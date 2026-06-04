# RUNTIME_NOTES — PS3/Lv2 global-address correctness (TOC stride + addressing model)

Branch `ppc-lv2-abi`. Goal: definitive yes/no on whether `getTOCEntry`'s global-address
computation is correct on `powerpc64-scei-lv2`, and fix it if not.

## Verdict (Phase A was conclusive — no execution needed to decide)

- **Addressing MODEL: CORRECT (not the bigger rewrite).** PS3 main EXECs use TOC-relative
  addressing through r2, with r2 (rtoc) initialised from the entry `.opd` descriptor. Our
  backend already emits exactly this model and — because Lv2 pointers are i32 — already emits
  the **ppc32-style `.got2` with 4-byte entries** (not the 8-byte ppc64 `.toc`), which matches
  the real PS3 toolchain byte-for-byte. So this is NOT the "absolute vs GOT-indirect" code-model
  rewrite that Phase D says to scope out.
- **TOC slot stride: 4 bytes.** Confirmed three independent ways (rpcs3 loader, real Sony EXECs,
  our own linker output).
- **Load WIDTH: WRONG — this is the bug.** `getTOCEntry` (`PPCISelLowering.cpp:3050`) emits a
  **64-bit `LDtocL` (`ld`)** of the TOC slot then `ISD::TRUNCATE`s to i32. With 4-byte `.got2`
  slots on big-endian, the 8-byte `ld` reads `[slot N][slot N+1]` and the low-32 truncate
  returns **slot N+1** — the wrong, adjacent pointer. **Phase D fix required:** a 32-bit
  zero-extending load. (This is consistent with the prior COPYREG_NOTES.md Finding 3 follow-up.)

## Evidence 1 — rpcs3 loader source (authoritative for the emulator target)

`rpcs3/rpcs3/Emu/Cell/PPUModule.cpp`:
- `ppu_load_exec()` (line 2097) loads a main EXEC at its **fixed** p_vaddr addresses and applies
  **NO relocations**: the phdr loop (lines 2408-2533) handles only `0x1` LOAD, `0x7` TLS,
  `0x60000001` process_param (SDK version / prio / **primary stack size** / malloc pagesize —
  struct at lines 2435-2446), and `0x60000002` proc_prx_param (libent/libstub import/export
  linkage, lines 2488-2524); everything else is "Unknown phdr type". There is no R_PPC64_* reloc
  switch here at all.
- Contrast `ppu_load_prx()` (line 1574): the PRX path DOES relocate, via the switch at lines
  1763-1829 — `R_PPC64_ADDR32` (type 1, **4-byte**, line 1765-1769), `R_PPC64_ADDR64`
  (type 38, 8-byte, line 1807), ADDR16_*/REL* etc. So pointer relocs that *do* exist are
  `R_PPC64_ADDR32` = 4-byte.
- Consequence: for a main EXEC, whatever the linker bakes into `.got2`/`.opd` is final; rpcs3
  reads the `.opd` rtoc word to set r2 and runs the code as-is. The TOC must therefore be
  statically correct at link time, which it is for a fixed EXEC.

(Syscalls for the canary are sourced separately from `Emu/Cell/lv2/` — see the canary section.)

## Evidence 2 — real Sony-toolchain EXECs (non-stripped, `reference-binaries/oldtoolchain/`)

All are ET_EXEC, EI_OSABI 0x66, BE PPC64, image base 0x10000, **no relocations** ("There are no
relocations in this file").

`gs_gcm_hello_world.elf`:
- `.got` (the TOC), addr 0x30140, **align 8** but entries are packed 4-byte addresses:
  `000492f0 000490c4 0004b9e0 0004b9e4 00010000 00023274 …` — every 4-byte word is a distinct
  nonzero address with **no interleaved zero high-words**. 8-byte zero-extended slots would show
  `00000000 000492f0 …`; they do not. ⇒ **4-byte slots.**
- `.opd` `{code,toc}` 8-byte entries; rtoc (r2) = **0x38140** = `.got`(0x30140) + 0x8000 — the
  standard "TOC base points 0x8000 into the TOC" convention.
- Disassembly: TOC access is `lwz rX, off(2)` (**32-bit load**) at **4-byte-stride** offsets
  `-32768, -32764, -32760, -32756 …(2)` (= -0x8000, -0x7ffc, -0x7ff8 …). Each `lwz` reads one
  4-byte slot. There is no 64-bit `ld` of a pointer slot.
- Across all 9 oldtoolchain binaries: `lwz off(2)` occurs 268–1525 times each; genuine
  `ld off(2)` only 1–3 times each (real 64-bit data, not pointer slots). The pointer TOC is
  universally 4-byte / `lwz`.

## Evidence 3 — our own clang+lld output already uses 4-byte `.got2` (and that's the mismatch)

- Our relocatable object for a bare global load (`probes/probe3.c`) emits the TOC entry into a
  **`.got2`** section as a **4-byte `R_PPC64_ADDR32`** relocation against the symbol (`.rela.got2:
  R_PPC64_ADDR32 g`). Mechanism: `PPCLinuxAsmPrinter::emitEndOfAsmFile`
  (`PPCAsmPrinter.cpp:2086-2103`) keys on `isPPC64 = (pointerSizeInBits()==64)`, which is **false**
  on Lv2 (pointers are i32), so it names the section `.got2` and emits each entry with
  `emitSymbolValue(target, 4)` — 4-byte, 4-aligned. So our slot width already matches Sony's.
- But `getTOCEntry` reads that 4-byte slot with `LDtocL` = a 64-bit `ld`. **Inconsistent by
  construction** → straddle.

### Empirical confirmation (diagnostic static link, not a run)
Linked `int test(){return a;}` (+ `test_b`/`test_c`) against `volatile int a=0x11,b=0x22,c=0x33;`
in a separate TU, with the patched `ld.lld` (`--image-base=0x10000`):
- Linked `.got2` @ 0x40248 = `00040254 00040258 0004025c` = `&a=0x40254, &b=0x40258, &c=0x4025c`
  — **4-byte packed slots**, confirmed.
- `test()` disassembles to `addis 3,2,1; ld 3,-32736(3); clrldi 3,3,32; lwa 3,0(3)`. The `ld`
  lands on `.got2` slot[0] (0x40248) and reads 8 bytes `00040254 00040258`; the `clrldi`
  low-32 = **0x40258 = &b**, so `test()` dereferences **b** and returns **0x22**, not 0x11.
  Likewise `test_b` → 0x33, `test_c` → the word past `&c` (garbage). This is precisely the
  Phase C "0x22 / 0x33 = adjacent-slot read" failure signature — demonstrated statically.

## Decision

Stride known (4 bytes), model confirmed (TOC-relative via r2, already `.got2`-based). Per the
task this is "conclusive → go straight to Phase D and use Phase C only to confirm the fix."
Phase D: make `getTOCEntry` emit a **32-bit zero-extending TOC load** on Lv2 (read exactly the
4-byte `.got2` slot, zero-extend into the g8rc base), removing the `ISD::TRUNCATE`. This also
removes the global-address path's reliance on the copyPhysReg `clrldi` backstop (the backstop
stays for other GPRC↔G8RC sites). Gate strictly on Lv2; non-Lv2 `getTOCEntry` unchanged.

The minimal canary (Phase B) is still built — as the human's Phase C confirmation artifact —
and after the fix `test()` must return 0x11.

## Phase D — the fix (done)

The 4-byte TOC slot must be read with a 32-bit zero-extending load. The slot width was
already correct (our AsmPrinter emits a ppc32-style `.got2` with `emitSymbolValue(...,4)` on
Lv2); only the *load* was 64-bit. Implemented as a new TOC-low pseudo selected on Lv2:

- `llvm/lib/Target/PowerPC/PPCInstr64Bit.td`: new `LWZtocL8` — same operands as `LDtocL`
  (g8rc result, `g8rc_nox0` base, `tocentry` disp), `mayLoad`, `isPPC64`.
- `llvm/lib/Target/PowerPC/PPCAsmPrinter.cpp`: lower `LWZtocL8` like `LDtocL` but to `LWZ8`
  (a 32-bit `lwz` that zero-extends into the 64-bit GPR) with the `@toc@l` (`S_TOC_LO`) ref.
- `llvm/lib/Target/PowerPC/PPCISelDAGToDAG.cpp`: in the medium-model GOT-indirect `TOC_ENTRY`
  branch, select `LWZtocL8` instead of `LDtocL` **iff `Subtarget->isLv2ABI()`**; the high half
  stays `ADDIStocHA8`. Non-Lv2 PPC64 unchanged (still `LDtocL`); 32-bit ELF/AIX unchanged.
- `getTOCEntry` itself is unchanged except a comment; its existing i64→i32 truncate now just
  drops the already-zero high half of a correctly zero-extended 32-bit load.

Verification:
- `probes/probe3.c` now selects `addis 3,2,@toc@ha; lwz 3,@toc@l(3); clrldi 3,3,32; lwa 0(3)` —
  `lwz` (4-byte) replaces the old `ld`.
- Re-linked the diagnostic (`int test(){return a;}` etc.): `.got2` still 4-byte slots
  `&a,&b,&c`; `test` now does `lwz 3,-32736(3)` → reads slot[0] = `&a` → returns **0x11**;
  `test_b` → 0x22; `test_c` → 0x33. The straddle is gone.
- `llvm/test/CodeGen/PowerPC/lv2-ptr-widen.ll` updated to assert Lv2 uses `lwz` (not `ld`) for
  the TOC slot and that non-Lv2 still uses `ld`. lv2 tests pass; `check-llvm-codegen-powerpc`
  shows the same 7 pre-existing failures (0 new); `check-lld` unaffected (only the unrelated
  X86/MachO baseline failure).

Residue / minor: the global-address path still emits one `clrldi` (the copyPhysReg backstop)
when the i32 result is used as a 64-bit base, even though `lwz` already zero-extended. It is
redundant-but-correct. Fully removing it needs address-mode selection to keep the value in
g8rc (the "peel the truncate" idea the copy task deferred) — recorded as a follow-up, not done
here.

## Phase B/C — canary (built; human runs)

`probes/canary/` — `data.c` (sentinels in a separate TU), `canary.c` (`_start` reads `a`,
exits `sys_process_exit3(a)`), `build.sh`, `README.md`, and the built `canary.elf`
(EI_OSABI 0x66, ET_EXEC, base 0x10000, entry = `_start` `.opd`, no relocations). rpcs3 boots
plain ELFs, so no signing is required; the README has the run steps and the
status→meaning table (17/0x11 = correct).

Incidental finding (out of scope, recorded for follow-up): a **direct call to a local
function** on Lv2 fails to select — `Cannot select: PPCISD::CALL_NOP … TargetGlobalAddress:i32
… Register:i64 $x2`. The ELFv1 call-with-TOC-restore-nop path isn't wired for Lv2's i32
GlobalAddress operand. This is a *call-lowering* gap, separate from global addressing; the
canary sidesteps it by folding the read into `_start`. Next task after this.
