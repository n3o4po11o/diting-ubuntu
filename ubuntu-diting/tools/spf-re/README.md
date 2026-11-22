# SPF reverse engineering toolchain (python + LLVM Hexagon)

Analysis of the ADSP firmware ELF (`/tmp/adsp-cn.mbn`, `/tmp/eea-adsp.mbn`)
driven from Python. Results are documented in `../../docs/AUDIO-SPF.md`.

## Why not capstone

capstone has **no Hexagon backend** in any release (5.0.x) and the capstone6
`next` branch (built and tested here) does not contain one either — the
backend was never merged. The disassembly engine is LLVM's Hexagon MC
disassembler (the one Qualcomm contributes to upstream LLVM), invoked from
Python via `llvm-objdump` (real VAs, `immext()` shown) and `llvm-mc`:

```sh
brew install llvm          # LLVM 22.x ships the hexagon target
llvm-objdump -d --triple=hexagon --mcpu=hexagonv68 \
    --start-address=0xb0100000 --stop-address=0xb0be8000 \
    --no-show-raw-insn /tmp/adsp-cn.mbn > seg18.txt
```

CPU is `hexagonv68` (SM8475 / 8+ Gen 1 ADSP).

## Files

| File | Purpose |
| --- | --- |
| `elfmap.py` | ELF32 Hexagon phdr parser, file-offset ↔ VA mapping (`elfmap.py fw.mbn 0x10395ea`) |
| `hexdis.py` | llvm-mc wrapper for raw buffers (byte-stream mode; use llvm-objdump for whole ELFs) |
| `xref.py` | raw 4-byte pointer scan + immediate scan for target VAs |
| `xref_pcrel.py` | pc-relative (`add(pc,##imm)`) reference scan |
| `func.py` | recover the function containing an address (allocframe → dealloc_return) |

## Gotchas learned (all cost real time)

1. **llvm prints some 32-bit immediates negative**: a string at
   `0xb07685b4` appears as `##-0x4f897a4c`. Always grep both
   `##0xVA` and `##-0x(0x100000000-VA)`. This is how all four SPF
   strings' xrefs were finally found.
2. Strings are referenced **absolutely** (`r0 = ##0xb0768611`) or via
   **base register + small offset** — never pc-relative in the audio image
   (the only `add(pc,##)` in seg18 is the 0xb0100000 entry stub).
3. `PT_LOAD` seg18 mixes code and rodata; llvm-objdump happily
   "disassembles" string bytes and data tables (`<unknown>` lines and
   bogus instructions). Validate xref hits against raw words before
   trusting them — the `/statichashes/*.so` manifest at 0xb075cb80 and
   the symbol table at 0xb0743890 both masquerade as code.
4. The audio image carries an embedded symbol table (0xb0743890,
   1804 × 16B entries `{va, size, flags, strtab-id}`, strtab at
   0xb074a95c) — but its name resolution does **not** line up with the
   audio-image VAs (resolves to libc names); it belongs to another
   object. Do not trust it for naming.

## Key addresses (CN = EEA here, both builds byte-identical in this code)

| Address | What |
| --- | --- |
| `0xb010b024` | `sys_init.c` main — gates + init chain, prints "Entering main() ..." |
| `0xb0149578` | audio image main — prints all four SPF strings, calls coremain, parks in signal-wait |
| `0xb01f5740` | coremain thunk → `0xb0614e74` (real coremain, rcinit registrations) |
| `0xf02031a0` | `gpr_init_adsp_kernel_wrapper` GPR INIT START (root PD, seg8) |
| `0xf021ce04`–`38` | fastrpc_thread_queue_qdi audiopd spawn (root PD, seg8) |
