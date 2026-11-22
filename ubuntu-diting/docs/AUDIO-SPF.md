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

## What has been excluded (all with evidence)

| Hypothesis | Evidence against |
| --- | --- |
| CN voice topology incompatible | Same timeout with the plain 11 KB device-package topology |
| Missing kernel audio components | cs35l41 ×2 with DSP firmware, wcd938x, all 4 lpass macros probe successfully |
| 1972 clock poisons the handshake | Same timeout after a time-correct ADSP remoteproc restart |
| Missing persist/audio calibration | Present on the real unit; protection DSP runs (5.91/7.21 Ω) |
| Failed userspace services | Zero failed units; all diting audio services active |
| Userspace holding the FEs | No process holds any /dev/snd node |

## Root cause hypothesis

The CN ADSP firmware (`adsp.mbn` from the CN ROM's firmware_mnt
partition) has a different SPF-to-GPR registration sequence than the
EEA firmware the upstream port was developed against. The mainline
kernel's `q6apm` driver expects the SPF to register GPR port 1 at
boot; the CN SPF does not (or registers it with a different
notification the driver doesn't handle).

## Fix approaches (in order of preference)

### Approach 1: EEA ADSP firmware (decisive, ~1 hour)

Replace the CN `adsp.mbn` with the EEA version and test:

1. Download the EEA fastboot ROM (OS3.0.5.0.VLFEUXM, ~5 GB).
2. Extract `firmware_mnt/image/adsp.mdt` + `adsp.b*` from the
   NON-HLOS.bin (modem partition image contains firmware_mnt).
3. Squash with `tools/firmware/mdt-squash.py` into a single
   `adsp.mbn`.
4. Install as `updates/qcom/sm8475/xiaomi/diting/adsp.mbn`
   (takes precedence over the extracted CN one).
5. Reboot and check `dmesg | grep qcom-apm`.

If the timeout disappears → confirmed firmware difference; either
keep the EEA adsp permanently (may lose CN-specific modem/voice
features) or proceed to approach 2.

### Approach 2: Kernel q6apm adaptation (proper fix, 2-5 days)

Reverse-engineer what the CN SPF expects:

1. **Capture GPR traffic**: enable `CONFIG_QCOM_GPR_DEBUG` (or add
   tracepoints to `q6apm.c`) to log every GPR packet at ADSP boot.
2. **Compare with ABL**: the Android bootloader successfully talks
   to the ADSP before Linux starts — use the vendor's DTB
   (`/proc/device-tree` from an Android boot) to check for
   different `qcom,glink` or `qcom,apr` properties.
3. **Check PDR/service registration**: the SPF may require a
   specific PDR domain notification before it registers its GPR
   port. The `q6apm` driver's `apm_probe()` may need to subscribe
   to a service first.
4. **Port the fix**: likely a small change to `q6apm.c`'s probe
   sequence (add a service subscription or retry loop) — patch
   0100.

### Approach 3: Bypass SPF for basic audio (workaround, 3-5 days)

If SPF is fundamentally incompatible, use the ADSP's "raw" audio
path that doesn't need graph management:

1. The `q6apm_raw` char device (`/sys/kernel/debug/q6apm_raw`)
   allows direct graph commands without the kernel's graph manager.
2. A userspace daemon could use this to set up basic PCM playback
   graphs manually.
3. This is how the bring-up was originally done (the author's early
   bring-up notes reference this path).

This is ugly but would give basic speaker output while the proper
fix is developed.

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
| **SPF handshake** | ❌ **timeout — the single blocking point** |

## Related documentation

- KNOWN_ISSUES.md: the original open issue entry (2026-11-21)
- CN-ADAPTATION.md: full CN adaptation history
- tools/firmware/diting-build-firmware: builds the topology files
- packages/modemmanager/0002: MM suspend fix (unrelated but same
  CN firmware pattern)
