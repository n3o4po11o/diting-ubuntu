# modemmanager (local rebuild)

Ubuntu's `modemmanager` source (version in `scripts/build-modemmanager.sh`,
fetched with `apt-get source` in the arm64 build chroot) plus the patches in
this directory, built as `<ubuntu version>diting3` (`LOCAL_SUFFIX` in the
script, raised for every patch added). `device-xiaomi-diting` pins `*diting*`
versions so the archive package does not replace it.

There is no ModemManager source tree in this repository to see the patches
applied in: the patches are kept here, next to the two source archives, and
the build script copies them into `debian/patches` of the archive version
and runs `quilt`. `git log -- ubuntu-diting/packages/modemmanager` shows
the commit that added each: `0001` in `739cc5b` (2026-10-14), `0002` in
`2f6d917` (2026-11-22), `0003` in `480bf10` (2026-11-25). The fixes of
2026-11-24 and 2026-11-25 for the restart, the redial, the network mode and
the NAS fields are not in ModemManager: they are the scripts and units of
`device-xiaomi-diting` (`b5ab5d9`).

- `0001-netlink-fix-use-after-free-...`: upstream commit 9317cbc4 (Dan
  Williams, 2026-10-04). `transaction_complete()` read `tr->completion_fn`
  after removing (and so freeing) the transaction; after a resume, when
  ModemManager re-creates the `qmapmux0.0` data link, the freed memory was
  reused and ModemManager jumped to a bad address (SIGSEGV, backtrace in
  `src/mm-netlink.c:242`). Mobile data dropped until systemd restarted it.
  It needs no suspend: dials failing in quick succession do the same
  (docs/KNOWN_ISSUES.md, 2026-11-24).
- `0002-Keep-the-modem-across-suspend-...`: the quick suspend/resume hooks
  as the build default (docs/ALWAYS-ONLINE.md).
- `0003-qmi-sim-slots-the-first-active-slot-with-a-SIM-is-the-primary-one`:
  not upstream. This modem reports both SIM slots as active; ModemManager
  took the last one as the primary slot, so with the SIM in slot 1 it
  showed the empty slot 2 as active and created a second SIM object for
  the card. Now the first active slot that has a SIM is the primary one
  (docs/KNOWN_ISSUES.md, 2026-11-25).

Drop the rebuild once the Ubuntu archive ships a version with the fixes.

## Check which build runs on the phone

The version string is only as good as the package it came from: on
2026-11-24 the owner's phone ran a package labelled `diting2` that had
0002 but not 0001 (a `/tmp/mm2.deb` of November 22, not this build), and
ModemManager segfaulted on every failed dial.

    md5sum /usr/sbin/ModemManager

| md5 | build-id | the build |
| --- | --- | --- |
| `a957b4b634a813214145db053232a5bb` | `bd674b97…` | diting3: 0001-0003 |
| `42702035b8bb7447377145b34a4271dd` | `dd771ddb…` | diting2: 0001, 0002 |

The diting2 build was reproduced byte for byte by a rebuild; the values
change with the toolchain in the chroot. `dpkg -V modemmanager` passing
means only that the files match whichever package was installed. Install
from `output/debs/` on the build host, together with `libmm-glib0` of the
same build.
