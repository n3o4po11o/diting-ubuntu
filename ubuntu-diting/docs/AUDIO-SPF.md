# Audio (SPF) fix roadmap on the CN diting

> **RESOLVED 2026-11-22 — sound works.** Root cause: the DT's
> `qcom,vmids = <LPASS ADSP_HEAP>` on the fastrpc node made the driver
> `qcom_scm_assign_mem()` the 12 MiB audio-PD heap away from HLOS; the
> next coherent allocation from that shared-dma-pool aborted in
> `dcache_clean_poc()` (synchronous external abort), the audio PD's heap
> stayed half-broken and the SPF never initialized. Removing
> `qcom,vmids` (non-secure domain, DSP reaches the heap via compute-cb)
> fixed the entire stack. Details and verification in the last section.

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
| 11 | CN lacks an EEA audio-protection calibration (variant of #5, in vendor acdbdata rather than persist) | raised 2026-11-22. Not covered by the #1 test (which swapped only adsp.mbn), but demoted: the disassembled boot path has no calibration/ACDB/persist read anywhere before the SPF handshake — all `calibration_*`/`vbatt` strings sit in graph-runtime CAPI code (0xb07c5xxx+), entered only at graph open; the speaker-protection calibration is present on the unit (5.91/7.21 Ω) and flows kernel/lpass→ALSA, not through SPF. Would be disproved by rootpd logs showing the stall at pool allocs / fastRPC init instead of a config read. |

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
- Largest regions cluster at offset `0x5B0000-0x600000` (later shown by
  RE to be an R-X **code** segment of the root PD — build drift, not
  configuration data; see the 2026-11-22 RE section below)
- **Zero difference regions near the SPF init strings** (`0x1039000`):
  the SPF initialization code is byte-identical between CN and EEA

This means the SPF code is the same; the difference is in data or
peripheral configuration that the SPF initialization checks before
starting.

## Next approach: reverse engineering with Python + capstone

> **STATUS: executed 2026-11-22 — see the next section for results.**
> capstone has no Hexagon backend in any release (nor in capstone6-next);
> the analysis was done with Python driving LLVM's Hexagon disassembler
> (`llvm-objdump -d --triple=hexagon --mcpu=hexagonv68`). Tooling and
> repro notes: `tools/spf-re/`.

### Goal

Find the conditional branch between `"Calling AudioPD coremain"`
(`0x1039621`) and `"Core Init for audio image done"` (`0x1039655`)
that skips SPF initialization, and identify what condition it tests.

## Reverse engineering results (2026-11-22)

### Headline: there is no conditional between the strings

All four SPF boot strings are printed by one function — the audio
image main at **`0xb0149578`** — as an unconditional straight-line
sequence (calls only, no branches):

```
0xb01495a8  log("Inside the audio Image Main function")   ; 0xb07685ea
0xb01495b8  log("user pid is %d")                          ; 0xb0768611
0xb01495c4  log("Calling AudioPD coremain")                ; 0xb0768621
0xb01495d0  call 0xb01f5740          ; coremain thunk -> 0xb0614e74
0xb01495d4  log("enabling elite framework")                ; 0xb076863b
0xb01495e0  log("Core Init for audio image done")          ; 0xb0768655
0xb01495ec  signal-wait loop forever  (qurt-style wait, 0xb0087904)
```

The logging goes through `0xb0109894` = vfprintf into the HLOS-visible
ADSP stdout sink (global at `0xb0beac28`). **So if the audio image main
ever runs, these lines are observable from Linux.** None of them ever
appeared on the CN unit ⇒ audio image main never executes. The skip
happens *before* main, not inside the string-to-string path.

(The xrefs were only findable because llvm prints some 32-bit
immediates negative — the strings appear as `##-0x4f897a16` etc.)

### Boot chain as recovered

```
root PD (seg8, VA 0xf0103000+)                 fastrpc_thread_queue_qdi.c
  └─ audiopd static-PD spawn 0xf021ce04..38   ("audiopd", /dev/fastrpc-smd)
     └─ adsprpcd's INIT_CREATE_STATIC + INVOKE land here   ← 3× EUNSUPPORTED

audio image (seg18, VA 0xb0100000+)
  sys_init.c main 0xb010b024
    gates: 0xb0109850("DEFAULT_PHYSPOOL", 0xb0c65000) + bss flag 0xb0cb00e8
           (flag referenced exactly once ⇒ always 0 ⇒ abort only if a
            pool/service call in the init chain fails; error logs
            "sys_init.c" lines 0x46/0x5c/0x60)
    12-call init chain (0xb010a1a0 … 0xb010bb50)
    log "Entering main() ...\n"               ; 0xb075636e
    audio image main 0xb0149578               ; the four strings
      └─ coremain 0xb01f5740 → 0xb0614e74     ; rcinit registrations
           ("initgroups", rcinit_lite_task.c, "RCInit Processing Done")
           gates: bss globals 0xb0c78308 / 0xb0c78318 (runtime-set)
      └─ parks in signal wait
```

GPR itself initializes in the root PD: `gpr_init_adsp_kernel_wrapper`
at **`0xf02031a0`** (diag "GPR INIT START", msg-const table at
`0xf030eae4`), gated on a lazily-initialized pointer at `0xf0801dc0`,
then registers GPR domain 2 (the audio domain — matches
`gprsvc:service:2:1`) via `0xf0203490` with config at `0xf036ce90`.

### CN vs EEA diff is build drift, not configuration

- seg8 (root-PD code, file `0x3d6000-0x609308`): 333,921 B differ,
  29,373 regions — this is what the earlier analysis called
  "0x5B0000-0x600000 calibration/configuration data". **It is an R-X
  code segment.**
- The seg8 *string sets* are identical except build stamps:
  CN `Q6_BUILD_TS_Thu_Jun_11_14:45:35_PST_2026`,
  EEA `Q6_BUILD_TS_Thu_Aug_20_11:31:47_PST_2026` (both "waipio.adsp.prod",
  OEM string `pangu-build-bp-…`). Two different ADSP.HT.5.7 builds.
- seg18 (audio image): 1,582 B differ — build hash strings, one
  CN/EEA-divergent set of log strings around 0xb078531a-0xb0785512
  (client-callback logging), and small immediate drift in the
  0xb01fd628-0xb01fda60 service-wrapper region. The four-string code
  path and coremain are byte-identical.

**Consequence:** Approach 1 ("patch CN data to match EEA") is dead —
there is no meaningful data difference to patch. This is consistent
with hypothesis 1 already being excluded (EEA fw on CN hw: same
timeout).

### Where the failure actually is

Since EEA firmware behaves identically on this unit, the blocker is
environmental — the kernel/userspace side of the fastRPC protocol, not
firmware content. The failing INVOKEs (`0x80000600` ADSP_EUNSUPPORTED)
are dispatched in the root PD by fastrpc_thread_queue_qdi's
`driver_invoke` (seg8, strings at `0xf0314c51`). The audio PD is
created but its userspace-facing methods are rejected, so sys_init
main never runs, so SPF/rcinit never start, so the APM GPR service
never registers and q6apm times out on `APM_CMD_GET_SPF_STATE`.

### Next steps (replaces old method section)

1. **Decisive on-device test:** capture ADSP stdout/diag (dprintf over
   the fastrpc/glink log channel) while restarting the ADSP. If
   "Inside the audio Image Main function" never appears, the failure
   is confirmed at the fastRPC INVOKE layer (before firmware main).
2. **Audit the Ubuntu kernel's fastrpc driver + adsprpcd version**
   against what ADSP.HT.5.7 expects for static-PD audiopd INIT_CREATE
   + INVOKE (method table in seg8 QDI). The mismatch is protocol-level.
3. Approach 3 (q6apm_raw bypass) remains the shortest path to sound.

## Userspace + service audit (2026-11-22, round 2)

### The 3 failing INVOKEs identified

`adsprpcd audiopd` (= `adsprpcd audiopd adsp`, qualcomm/fastrpc @
a56e9d4, built by `make packages` as fastrpc-diting) does:

1. `remote_handle64_open("createstaticpd:audiopd&dom=adsp")`
   → FASTRPC_IOCTL_INIT_CREATE_STATIC — **the call that succeeds**
2. `adsp_default_listener1_open("adsp_default_listener1&dom=adsp")`
   → INIT_CREATE + **INVOKE — fails 0x80000600**
3. `adsp_default_listener1_register(fd)` → **INVOKE — fails**
4. `geteventfd` open → third failing INVOKE

EUNSUPPORTED (not a timeout) means the audio PD **is alive and
dispatching** — its method lookup rejects the listener1 URI/method.

### Firmware side: registration is static, nothing to load

The audio image registers its fastRPC services statically; no DSP
files are involved (the `file:///libadsp_default_listener1_skel.so`
URI in the registration cascade is just a name):

- QDI driver table in seg19 initial data at `0xb0bec200`+:
  `audio_pd` ("msm/adsp/audio_pd"), `HAP_utils`, `platform_qdi`,
  `fastrpc_uprocess` (init = `0xb012b4c4`), `listener`, `mod_table`,
  `HAP_pool`, `perf`, `platform_fs` — each {0, -1, init_fn, open_fn,
  name}.
- `fastrpc_uprocess_init` (`0xb012b4c4`, fastrpc_uprocess.c) registers
  in order: perf_getmsg, adsp_process_group, adsp_current_process(1),
  adsp_default_listener (static table `0xb012d81c`), then
  adsp_default_listener1 (static table `0xb012d84c`, name
  "file:///libadsp_default_listener1_skel.so?...&_modver=1.0").
  Early gates before the registrations: one-time 0x3b8-byte pool alloc
  (`0xb01053dc`), `0xb02214b4`, and `0xb010b430` — any failure logs
  "Error 0x%x: %s failed" (code 0x833, fastrpc_uprocess.c) and aborts,
  leaving listener1 unregistered ⇒ EUNSUPPORTED for exactly the calls
  above.
- Both the QDI table and the listener skel tables are **byte-identical
  CN↔EEA**.

Also audited the dsp partition (CN + EEA `dspso.bin`): `adsp/` holds
the 42 dynamic modules (codec/fluence DSOs + `fastrpc_shell_0` +
sysmon skels) — correctly shipped by diting-build-firmware to
`usr/share/qcom/sm8475/Xiaomi/diting/dsp/adsp` with
`ADSP_LIBRARY_PATH` in diting-audiopd.service. No listener skel is
needed from there.

### The diagnostic blind spot: no rootpd daemon

The port ran only `diting-audiopd.service`. On Android a second
daemon, `adsprpcd rootpd`, attaches to the root PD; that attach starts
**adspmsgd** (`fastrpc_apps_user.c`: adspmsgd_init on ROOT_PD attach,
"enable PD exception logging"). Without it:

- the ADSP dprintf buffer (audio PD boot logs, the
  `Error 0x833: fastrpc_uprocess.c` failures, "Entering main() ...")
  is pumped nowhere,
- audio PD **exception dumps** (crash location!) never reach HLOS.

So the SPF timeout has been debugged without any visibility of the
side that actually fails.

**Fix (in this tree):** `diting-rootpd.service` added
(packages/device-xiaomi-diting/systemd/), started by the existing
`90-diting-audiopd.rules` (ordered Before=diting-audiopd.service so
the log pump is up before the audio PD is created), preset-enabled and
in debian/install.

### Decisive test after installing the new unit

Zero-deploy variant (no package rebuild needed — run the daemon in the
foreground as the log pump):

```sh
# host: tools/diting-link.sh, then
ssh -i ~/.ssh/diting_debug_key ubuntu@172.16.42.1
# on the tablet:
sudo -b /usr/sbin/adsprpcd rootpd > /tmp/rootpd.log 2>&1   # pumps ADSP dprintf
sudo sh -c 'echo stop > /sys/kernel/debug/remoteproc/remoteproc*/state'
sudo sh -c 'echo start > /sys/kernel/debug/remoteproc/remoteproc*/state'
sleep 8; cat /tmp/rootpd.log
```

With the packaged unit (after `make packages` + reinstall):

```sh
journalctl -u diting-rootpd -f &            # ADSP dprintf now lands here
# restart the ADSP (from the port's usual debugfs path)
echo stop > /sys/kernel/debug/remoteproc/remoteproc*/state
echo start > /sys/kernel/debug/remoteproc/remoteproc*/state
```

Interpretation:

| What appears in diting-rootpd logs | Conclusion |
| --- | --- |
| `Error 0x833: ... failed` (fastrpc_uprocess.c) | audio PD boots, uprocess init aborts at the named call — follow that call |
| PD exception/crash dump | audio PD crashes during init — address in dump maps to the failing stage |
| `Entering main() ...` / `Inside the audio Image Main function` | audio main runs; SPF failure is deeper (rcinit tasks) — revisit `0xb0c78308`/`0xb0c78318` gates |
| nothing at all | audio PD never starts executing; problem is in the root-PD spawn path (seg8 fastrpc_thread_queue_qdi) or the kernel fastrpc driver |

## Fix approaches (in order of preference)

> Re-prioritized 2026-11-22 after RE: the SPF skip is not a firmware
> data/config issue (CN/EEA differ only by build), so Approach 1 is
> retired. The failure sits at the fastRPC static-PD protocol layer
> (kernel fastrpc driver / adsprpcd ↔ root-PD QDI).

### Approach 1 (retired): Reverse engineer + patch data

~~If the SPF skip is caused by a data value that differs between CN and
EEA (in the `0x5B0000-0x600000` region), patch the CN firmware's data
to match EEA.~~ The RE showed the diff region is root-PD **code** from
a different ADSP build date and the audio-image boot path is
byte-identical; there is no config value to patch.

### Approach 2 (now primary): fix the fastRPC audiopd protocol path

The 3 INVOKEs after INIT_CREATE_STATIC fail with ADSP_EUNSUPPORTED in
the root PD's `fastrpc_thread_queue_qdi` driver_invoke. Audit the
Ubuntu kernel's fastrpc driver and adsprpcd build against the
ADSP.HT.5.7 static-PD expectations (method dispatch in seg8). This is
where audio main is being prevented from ever running.

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

## RESOLUTION (2026-11-22, on-device session)

### The smoking gun

With `adsprpcd rootpd adsp` running as an ADSP log pump and the ADSP
restarted while watching dmesg, the audio chain showed:

```
[5445.123] PDR: Indication received from msm/adsp/audio_pd, state: 0x1fffffff
           → the audio PD boots; its PDR service is UP
[5445.174] Internal error: synchronous external abort: 0000000096000010
           CPU:0 PID:71002 Comm: adsprpcd
           pc : dcache_clean_poc+0x24          lr : arch_dma_prep_coherent
           dma_direct_alloc → dma_alloc_attrs → __fastrpc_buf_alloc
           → fastrpc_device_ioctl      (x0/x1: a 3 MiB clean range)
[5450.221] qcom-apm gprsvc:service:2:1: CMD timeout for [1001021]
```

The audio PD's fastrpc runtime itself was healthy this boot
(`createstaticpd:audiopd` OK, `adsp_default_listener` registered OK —
the earlier "3 INVOKEs EUNSUPPORTED" state does not reproduce on a
fresh ADSP boot; it was a downstream symptom of the same corruption).
What broke: the DT gave the fastrpc node a `memory-region`
(`adsp-rpc-remote-heap`, 12 MiB reusable shared-dma-pool) **and**
`qcom,vmids = <LPASS ADSP_HEAP>`. On INIT_CREATE_STATIC,
`fastrpc_remote_heap_alloc()` calls `qcom_scm_assign_mem()` → the
firmware fences those pages from HLOS. The kernel keeps allocating
coherent buffers for fastrpc ioctls from the *same* pool → the next
`dcache_clean_poc()` on those pages → synchronous external abort.
Heap half-broken → SPF init (module/graph memory) dies silently →
APM never registers → q6apm timeout → no card.

### The fix

Remove `qcom,vmids` from the fastrpc node (kernel patch 0045, updated
2026-11-22 with the full rationale). The node is
`qcom,non-secure-domain`: without vmids the DSP maps the heap through
the compute-cb context banks, which upstream mainline always does.

On-device verification sequence (2026-11-22):

1. `fdtput -d` the `qcom,vmids` property from the installed
   `/usr/lib/linux-image-7.2.10-diting/qcom/sm8475-xiaomi-diting.dtb`
   (backup kept as `.dtb.orig`),
2. `diting-mkbootimg --release 7.2.10-diting`, flash
   `boot-7.2.10-diting.img` + `vendor_boot-7.2.10-diting.img` to the
   active slot (`/var/lib/diting-boot-backup/` holds the originals),
   reboot.

Results after reboot:

- 0 external aborts, 0 q6apm CMD timeouts (was: immediate timeout)
- `XIAOMI-DITING` sound card registers; WirePlumber sees "Built-in Audio"
- pcm open initially EINVAL: the DAPM path needs the UCM EnableSequence
  (`TERTIARY_TDM_RX_0 Audio Mixer MultiMedia1` = 1, `Top MUX` = Speaker);
  with the switches set, `speaker-test -D hw:0,0 -c2 -t wav` is audible
  and error-free — **sound works**.

### Two more port bugs found on the way

1. **`diting-audiopd.service`/`diting-rootpd.service` argument form:**
   `adsprpcd rootpd` (one arg) takes the non-domain path and opens
   `createstaticpd:rootpd` instead of attaching the root PD. Use the
   two-arg form (`adsprpcd rootpd adsp` / `adsprpcd audiopd adsp`);
   the rootpd service unit is fixed in-tree.
2. **`alsa-ucm-conf` was not installed** → `/usr/share/alsa/ucm2/ucm.conf`
   missing → UCM resolution failed for every card → WirePlumber fell
   back to ACP and its pcm probe (mixer still off) failed → only a
   Dummy sink even with the card working. Fixed: `alsa-ucm-conf` added
   to device-xiaomi-diting Depends (and installed on-device:
   `alsaucm -c 0 list _verbs` now returns HiFi).

### Remaining polish — COMPLETED (2026-11-22, same session)

Full-duplex system audio now comes up on a cold boot with no manual
steps. The WirePlumber integration needed two more pieces, both now in
the port (and verified on-device):

1. **`diting-audio-mixer.service`** (one-shot after sound.target): sets
   the DAPM speaker path (TERTIARY_TDM mixer + Top MUX = the UCM
   BootSequence/HiFi speaker set) **and the full WCD938x mic chain**
   (ADC1/ADC4, DEC/SMIC muxes = the UCM Mic EnableSequence).
   WirePlumber 0.5 has no UCM verb path (`applyDefaultDeviceProperties`
   forces `api.alsa.use-acp=true`, and the 0.5 split-PCM monitor has no
   verb/profile machinery — verified against alsa.lua and
   spa/plugins/alsa), so nothing would ever run those sequences.
   Without them the capture graph delivers zero buffers (pw-record:
   `ticks:0 avail:0` forever) even though the pcm opens.
2. **`/etc/wireplumber/wireplumber.conf.d/51-diting-alsa.conf`**: sets
   `api.alsa.use-acp = false` for alsa_card.platform-sound so WP uses
   the raw split-PCM device instead of ACP probing (ACP opens the pcm
   during profile probe → fails → only a dummy sink).

Verified on-device after a simulated cold start (mixer off → unit →
WP restart): sink (vol restored, unmuted) and source appear
automatically; `pw-play` plays; `pw-record` captures real ADC data
(237k frames, ambient-noise peak). Known benign leftover: one
`q6apm` CMD timeout at ~13 s during boot (probe races the audio PD
creation before adsprpcd runs; every later graph open succeeds).
