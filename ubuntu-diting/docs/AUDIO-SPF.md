# Audio (SPF) fix roadmap on the CN diting

## Current state: no sound at all

Every playback open fails; WirePlumber creates only a dummy sink. The
kernel's audio card exists (ALSA sees the FEs) but no graph can be
created.

    qcom-apm gprsvc:service:2:1: CMD timeout for [1001021] opcode

`0x01001021` is `APM_CMD_GET_SPF_STATE` — the q6apm driver's probe
handshake with the ADSP's audio processing framework (SPF). The CN
ADSP firmware's SPF never registers its GPR port, so every subsequent
graph operation fails.

## Architecture (what talks to what)

```
userspace (WirePlumber/pipewire)
  ↓ ALSA
kernel snd-sc8280xp (machine driver)
  ↓ DPCM
kernel q6apm (audio graph manager)
  ↓ GPR (generic packet router) over glink
ADSP firmware: SPF (audio processing framework)
  ↓ internal graphs
ADSP firmware: lpass macros (rx/tx/wsa/va), WCD938x codec,
               CS35L41 smart amps
```

The failure is at the `q6apm ↔ SPF` handshake (arrow 3). Everything
above (machine driver, DPCM, FEs) and below (macros, codec, amps)
works — the DSP boots, its PDR services respond, the speaker
protection firmware loads with calibrated impedance values.

## Root cause: SPF never starts inside the ADSP (confirmed 2026-11-22)

**QRTR service list proves it** — the ADSP (node 5) registers 8
services (thermal, SLIMbus, subsystem control, CoreSight) but **zero
audio services** (no APM, no PRM, no audio graph). The GPR device
`gprsvc:service:2:1` exists only as a kernel-side DT definition; the
ADSP-side service behind it never starts.

The firmware contains the complete SPF boot chain (strings at known
offsets):

| String | File offset | Meaning |
| --- | --- | --- |
| `Inside the audio Image Main function` | `0x10395ea` | audio image entry |
| `Calling AudioPD coremain` | `0x1039621` | audio PD main() |
| `enabling elite framework` | `0x103963b` | Qualcomm audio framework |
| `Core Init for audio image done` | `0x1039655` | SPF ready |
| `Protection Domain Launched` | `0x595acb` | PD lifecycle |
| `GPR INIT START` | `0x6470b4` | GPR initialization |

"Core Init for audio image done" exists in the binary — the SPF code
is present. The execution path from `AudioPD coremain` to `Core Init`
has a conditional branch that skips it on this hardware.

## Excluded hypotheses (10 items, all with evidence)

| # | Hypothesis | Evidence against |
| --- | --- | --- |
| 1 | CN ADSP firmware incompatible | EEA firmware: same SPF timeout |
| 2 | CN voice topology incompatible | Plain 11 KB topology: same timeout |
| 3 | Missing kernel audio components | cs35l41 ×2 + DSP fw, wcd938x, all 4 macros probe |
| 4 | 1972 clock poisons handshake | Same timeout after time-correct ADSP restart |
| 5 | Missing persist/audio calibration | Present on real unit (5.91/7.21 Ω) |
| 6 | Failed userspace services | Zero failed units |
| 7 | Userspace holding FEs | No process holds /dev/snd |
| 8 | DSP library version difference | CN vs EEA: 42 .so files, all md5 identical |
| 9 | Kernel config regression | Full diff r46 vs r51: 0 audio-related changes |
| 10 | dma_heap cache corruption | InaccessiblePaths working, strace confirms |

## Audio PD investigation (2026-11-22)

`adsprpcd audiopd` (the userspace daemon that loads the audio PD):
- `FASTRPC_IOCTL_INIT_CREATE_STATIC` → **succeeds** (PD created)
- `FASTRPC_IOCTL_INVOKE` × 3 → **all fail** with `0x80000600`
  (ADSP_EUNSUPPORTED)

The failing handles differ from the successfully opened ones — the PD
was created but its internal initialization is incomplete. The SPF
depends on this PD being fully initialized before it registers.

## Firmware binary analysis (2026-11-22)

**CN vs EEA binary diff:**
- 340,392 differing bytes (1.4% of 23.5 MB)
- 30,686 contiguous difference regions
- Largest regions cluster at offset `0x5B0000-0x600000` (likely
  calibration/configuration data, not code)
- **Zero difference regions near the SPF init strings** (`0x1039000`):
  the SPF initialization code is byte-identical between CN and EEA

This means the SPF code is the same; the difference is in data or
peripheral configuration that the SPF initialization checks before
starting.

## Next approach: reverse engineering with Python + capstone

### Goal

Find the conditional branch between `"Calling AudioPD coremain"`
(`0x1039621`) and `"Core Init for audio image done"` (`0x1039655`)
that skips SPF initialization, and identify what condition it tests.

### Method

```python
# 1. Disassemble the region around the SPF init strings
from capstone import Cs, CS_ARCH_HEXAGON, CS_MODE_DEFAULT
md = Cs(CS_ARCH_HEXAGON, CS_MODE_DEFAULT)

fw = open("/tmp/adsp-cn.mbn", "rb").read()

# 2. Find the function that references these strings
#    (strings are in a data region; find the code that loads their
#     addresses into registers — typically PC-relative or absolute)

# 3. Trace execution from the function entry:
#    - Follow all basic blocks
#    - At each conditional branch, note:
#      * what register/condition is tested
#      * what the taken/not-taken paths do
#    - Identify which branch leads to "Core Init done" vs skip

# 4. Find what the condition depends on:
#    - A memory-mapped I/O read (hardware ID / peripheral check)?
#    - A data value from a calibration/configuration region?
#    - A response from another ADSP subsystem?

# 5. Compare with the EEA firmware at the same code location
#    (the code is identical, but the DATA it reads may differ)
```

### Key offsets for analysis

| What | Offset | Notes |
| --- | --- | --- |
| ELF file | 32-bit LSB, Hexagon QDSP6, statically linked | no section headers |
| SPF entry strings | `0x10395ea`–`0x1039655` | data region |
| GPR init string | `0x6470b4` | in gpr driver code |
| PD launched string | `0x595acb` | PD lifecycle |
| CN/EEA diff clusters | `0x5B0000`–`0x600000` | 1 KB regions, likely config data |
| SPF code region | identical CN/EEA | no binary diff here |

### Alternative: radare2 quick analysis

```sh
r2 -a hex /tmp/adsp-cn.mbn
# search for string references
> / Calling AudioPD coremain
# find cross-references to the string
> axt @ <string_address>
# disassemble the function
> pdf @ <xref_address>
```

### Alternative: Ghidra (requires Hexagon plugin)

Import `/tmp/adsp-cn.mbn`, set language to Hexagon (QDSP6), auto-analyze.
Search for "Calling AudioPD coremain", find xrefs, trace the code path.

## Fix approaches (in order of preference)

### Approach 1: Reverse engineer + patch data (if the condition reads a config value)

If the SPF skip is caused by a data value that differs between CN and
EEA (in the `0x5B0000-0x600000` region), patch the CN firmware's data
to match EEA. This is a firmware-level fix, applied at the
`diting-build-firmware` stage.

### Approach 2: Reverse engineer + patch kernel (if the condition is in DT/hardware)

If the SPF checks a hardware ID or peripheral that we can control from
the DT, patch the DT to make the check pass.

### Approach 3: Bypass SPF (workaround)

Use `q6apm_raw` char device to set up basic PCM graphs directly,
bypassing the SPF's initialization check. Gives basic speaker output
while the proper fix is developed.

## Hardware that works (verified)

| Component | Status |
| --- | --- |
| CS35L41 smart amps (both) | ✅ probe + DSP firmware + calibrated R |
| WCD938x codec (headset) | ✅ probe + soundwire bound + MBHC jack |
| lpass rx/tx/va/wsa macros | ✅ all probe |
| Speaker protection service | ✅ runs with factory calibration |
| Headset jack detection | ✅ input device registered |
| ADSP remoteproc | ✅ boots, PDR services respond, no crashes |
| q6apm module | ✅ loads, probes the GPR device |
| **SPF handshake** | ❌ **SPF never starts inside the ADSP** |

## Related documentation

- KNOWN_ISSUES.md: the original open issue entry (2026-11-21)
- CN-ADAPTATION.md: full CN adaptation history
- tools/firmware/diting-build-firmware: builds the topology files
- packages/modemmanager/0002: MM suspend fix (unrelated but same
  CN firmware pattern)
