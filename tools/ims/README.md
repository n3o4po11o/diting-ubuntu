# IMS tools (Python on the phone, Ghidra on the host)

The tools of the VoLTE investigation of 2026-11-25. The IMS stack is in the
modem firmware; what Android's telephony stack does on the AP side for it,
the IMS data call, the IMS data service (QMI 0x302), the IMS settings and the
carrier configuration, is done here by hand. The findings, the requests in
hex and what each one did on this phone are in
[`ubuntu-diting/docs/KNOWN_ISSUES.md`](../../ubuntu-diting/docs/KNOWN_ISSUES.md)
("VoLTE", and the record of that day on ModemManager and IMS). None of it
starts the registration: there is no VoLTE call yet.

Nothing here is in the image. The eight `diting-*.py` are copied to the phone
and run with `python3 -I`; `vendor-libs/` reads the Android vendor libraries
on the host.

## On the phone

```sh
scp -i ~/.ssh/diting_debug_key tools/ims/diting-*.py ubuntu@<phone>:/tmp/
ssh -i ~/.ssh/diting_debug_key ubuntu@<phone> 'cd /tmp && python3 -I diting-ims.py status'
```

All eight go into one directory: three of them load another one from next to
themselves. `diting-rawqmi.py` needs `qrtr-tools`; `diting-ims.py` and
`diting-pdc-names.py` python3-gi with gir1.2-qmi-1.0 and gir1.2-qrtr-1.0.
An unknown command prints the usage. Without arguments
`diting-rawqmi.py`, `diting-efs.py` and `diting-imscall.py` print it too,
`diting-ims.py` runs `status`, `diting-pdc.py` and `diting-pdc-names.py` list
the software configurations, and `diting-dcm.py` hosts the service for 300 s.
Remove them from the phone afterwards.

| Tool | Does | Root |
| --- | --- | --- |
| `diting-rawqmi.py SERVICE-HEX MSGID-HEX TLVS-HEX ...` | sends any QMI request over QRTR, the TLVs in hex (`-` for none), and prints the response with its TLVs. Example: `03 0024 -`, NAS Get Serving System | no |
| `diting-pdc.py list`, `selected`, `default [hw\|sw]`, `send MSGID TLVS-HEX [SECONDS]` | the carrier configuration service (PDC, 0x24) with raw QMI: the configurations by their ids, the selected and the default one; `send` takes any request and prints the indications for a while | no |
| `diting-pdc-names.py [hw\|sw] [id HEX-ID ...]` | the descriptions of the configurations, through libqmi's encoding of Get Config Info | no |
| `diting-efs.py [SUB] PATH ...` | reads files of the modem's EFS through Xiaomi's extension service (0xFFE4). Reading only | no |
| `diting-ims.py status`, `watch SECONDS`, `settings [enable]`, `pdc [SECONDS]`, `selected`, `pdc-load FILE`, `pdc-select ID` | IMSA registration and services, IMS settings and PDC through libqmi | no |
| `diting-dcm.py [SECONDS] [COMMAND-FILE] [--reg HEX\|none] [--pdp N]` | hosts the IMS data service (0x302) for the modem and answers its requests; indications go out from lines in the command file | no |
| `diting-imshelper.py MUX-ID [SECONDS] [COMMAND-FILE] ...` | the same, and brings the IMS data call and its link up when the modem asks for it | yes |
| `diting-imscall.py MUX-ID [SECONDS] [COMMAND-FILE]` | brings the IMS data call up by hand and keeps it until the time is up or `quit` is in the command file | yes |

`hw` is the platform (hardware) configuration of PDC, `sw` the software one.

## Before running the ones that change something

- **An rmnet link on `rmnet_ipa0` carries the port's data format flags, or
  the modem asserts.** `rmnet_newlink` keeps the format per physical port and
  resets it for every link created without flags; frames then leave in a
  format the modem's IPA does not expect (`IPA Assert`, remoteproc recovery).
  Both tools that create a link read the flags of the port's existing links
  and pass them along. A link made by hand needs
  `ingress-deaggregation on ingress-mapv5-checksum on egress-mapv5-checksum on`.
  Two modem crashes on 2026-11-25.
- **Network modes are changed through ModemManager**
  (`mmcli -m 0 --set-allowed-modes=... --set-preferred-mode=...`), not with a
  raw NAS Set System Selection Preference: the raw write did not take, and
  the wrong restore cost eight minutes without service.
- **rmtfs runs with `-r` here.** The modem's EFS is read from its partitions
  into memory, so what the tools write to it (a selected carrier
  configuration, an EFS item) lasts until rmtfs starts again, which is a
  reboot of the phone.
- **A carrier configuration is activated online** (PDC Activate, 0x27), not
  by stopping and starting the modem: the cold restart lost IMSA and IMSS
  and the selection with them. Deactivate does not last over a modem restart.
- **`pkill -f` over ssh ends the session too** when the pattern matches the
  remote shell's own command line: `[d]iting-dcm` does not match itself.

## The IMS data call the modem accepts

From one WDS client: Bind Subscription (the primary one), Bind Mux Data Port
(embedded, interface 1, the mux id), then Start Network (0x0020) with APN
`ims`, IP family IPv6 (0x19 = 6), extended technology preference link-local
(0x34 = 0x8888) and call type embedded (0x35 = 1). The call has one
`fe80::/64` address and a gateway. It is stopped by its owner, with the
packet handle. When the modem refuses a call, `diting-imscall.py` prints the
result, the error and the response's TLVs; the ones it met on this phone are
in KNOWN_ISSUES.

## `vendor-libs/`: the Android vendor libraries on the host

What Android does is in the vendor libraries of the phone (`/vendor/lib64`:
`libqmiservices`, `libqmi_common_so`, `lib-imscommon`, `libqcrilNrImsModule`,
`libdsi_netctrl`, `libxiaomi_qcril`, ...). They are Qualcomm's and Xiaomi's,
so they are not in the repository; neither is the Ghidra project. `IMS_STUDY_DIR`
is the directory that holds both, the working directory if it is not set:

```
<study>/
├── vendor/lib64/           the vendor libraries
└── ghidra/
    ├── project/ImsProject  the Ghidra project
    └── out/                decompiled C, disassemblies, logs
```

| Tool | Does |
| --- | --- |
| `idl_dump.py LIBRARY [SERVICE-OBJECT ...]` | of every `<name>_qmi_idl_service_object_v<n>`: the service id, the message ids and the raw TLV descriptors. The layout is the one of `qmi_idl_lib_internal.h` of Qualcomm's qmi-framework |
| `idl_tlvs.py LIBRARY SERVICE-OBJECT MSGID-HEX ...` | the TLVs of those messages decoded: type, element, offset in the C structure |
| `qmi_calls.py DISASSEMBLY` | from `llvm-objdump -d -C` output: every call of `qmi_client_send_msg_sync` with the message id loaded into `w1`, and the functions that call the other QMI entry points |
| `disasm_refs.py DISASSEMBLY REGEX [--all]` | the disassembly lines that name a symbol, with the function around them |
| `headless.sh LIBRARY OUT-DIRECTORY REGEX [MAX-FUNCTIONS] [CALLEE-DEPTH]` | imports a library into the project and decompiles the functions whose names match the regular expression, with their callees: one C file each and `index.txt`. The output directory must not exist yet or be empty |
| `process.sh PROGRAM-NAME SCRIPT [ARG ...]` | runs one of the three scripts on a library that is already in the project, without importing or analysing it again |
| `DecompileAt.java` | args `OUT-DIRECTORY CALLEE-DEPTH ADDRESS ...`: the functions containing the addresses |
| `DecompileMatching.java` | args `OUT-DIRECTORY REGEX [MAX-FUNCTIONS] [CALLEE-DEPTH]`: what `headless.sh` runs |
| `DecompileWithSwitch.java` | args `OUT-FILE SWITCH-ADDRESS TABLE-ADDRESS COUNT ELEMENT-SIZE SCALE BASE`: gives an indirect branch its jump table (`target[i] = base + scale * element[i]`), then decompiles the function around it |
| `lib.sh` | `IMS_STUDY_DIR`, `GHIDRA_HOME`, and the run of `analyzeHeadless`: Ghidra's GNU demangler sometimes starts and never answers, and the run waits forever with no CPU; it is stopped when the log makes no progress |

```sh
export IMS_STUDY_DIR=~/work/redmi-k50ultra/ims-study
export GHIDRA_HOME=/opt/homebrew/Caskroom/ghidra/11.2.1-20241105/ghidra_11.2.1_PUBLIC
V=$IMS_STUDY_DIR/vendor/lib64
T=tools/ims/vendor-libs
python3 -I $T/idl_dump.py $V/lib-imscommon.so
python3 -I $T/idl_tlvs.py $V/libqmiservices.so wds_qmi_idl_service_object_v01 20
llvm-objdump -d -C $V/lib-imscommon.so > $IMS_STUDY_DIR/ghidra/out/lib-imscommon.dis
python3 -I $T/qmi_calls.py $IMS_STUDY_DIR/ghidra/out/lib-imscommon.dis
$T/headless.sh $V/lib-imscommon.so $IMS_STUDY_DIR/ghidra/out/dcm 'ImsQmiDcm' 200 1
$T/process.sh lib-imscommon.so DecompileAt.java OUT-DIRECTORY 0 ADDRESS
```

`llvm-objdump` is LLVM's (`brew install llvm`). `GHIDRA_HOME` has no default:
the project was made with Ghidra 11.2.1, and a newer Ghidra upgrades a
project when it opens it, after which the older one cannot open it.
`headless.sh` writes Ghidra's log next to the output directory
(`OUT-DIRECTORY.log`), `process.sh` to `ghidra/out/<script>.log`.
