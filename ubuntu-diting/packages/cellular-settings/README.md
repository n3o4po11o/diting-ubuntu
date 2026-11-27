# cellular-settings

Cellular Settings: a GTK 4 and libadwaita window for what the desktop's
settings leave out for the cellular modem. Rust (`gtk4` 0.11,
`libadwaita` 0.9, `zbus` 5), English and Simplified Chinese. The phone's
own configuration (the APN, the network mode, the NAS preference) is set
in it; nothing has to be edited by hand after an install.

- **Status**: the state of the modem, operator, access technology, signal,
  power, firmware; registration, packet service, and the last reason the
  network gave for a refusal; the EPS UE mode of operation as the modem
  reports it, and the network mode. A banner when the network refused the
  modem because it has no 2G/3G network for it.
- **Network**: the EPS "UE mode of operation" (four modes, each explained
  in plain words, with a list of what the words mean); the network mode;
  Apply. With "Keep for next boot" the choice is also written to
  `/etc/diting/modem-mode`, which `diting-modem-setup` reads at every
  boot; "Forget" removes the file.
- **Mobile data**: the connections of type `gsm` of NetworkManager, with
  their access point; new, edit, delete; Connect. A new connection dials
  once before it leaves the retries to the redial watchdog
  (`connection.autoconnect-retries 1`); a connection that has no such
  setting shows NetworkManager's own default, four.

## What was learned on the phone (2026-11-26 and 27)

These are why the program is as it is.

- **The system bus does not let a process that is not root call
  ModemManager for anything but a list.** `org.freedesktop.ModemManager1.conf`
  allows `org.freedesktop.DBus.Properties`,
  `org.freedesktop.DBus.ObjectManager` and a list of members
  (`SetCurrentModes`, `SetEpsUeModeOperation`, `Simple.GetStatus`, ...);
  the rest is denied. `GetModems` is not in it: dbus-daemon refuses it with
  AccessDenied. The modems are listed through `GetManagedObjects`.
- **ModemManager's `SetEpsUeModeOperation` did not change the modem.**
  Twice on 2026-11-26 it answered "successfully set" and showed the new
  mode, and the modem still reported the old usage and service domain. The
  tool of the device package, `diting-nas-pref`, changes them in a second
  with the data connection up: it sends them with a QMI client of its own
and reads them back until the modem agrees. It needs no privilege. The
program uses the tool where it is (it asks the modem itself whenever the
window is refreshed, at most 20 s apart, and again right after every
Apply), and uses ModemManager's method only where the tool is not.
- **ModemManager refuses a network mode it does not list for the modem.**
  `SetCurrentModes` answers "The given combination of allowed and
  preferred modes is not supported" for any pair outside `SupportedModes`.
  The list of this modem has 28 pairs: 2G alone and 3G alone, without a
  preference, and 26 with one preferred technology each. It has none with
  4G or 5G alone and none with several technologies but no preference
  (ModemManager leaves those out for a multimode device, one with
  CDMA/EVDO and GSM/UMTS in its capabilities). So the program offers only
  the pairs that are listed (9 of its 19 presets here), and says on the
  page what the list leaves out. A patch to ModemManager that adds 4G
  alone, 5G alone and 4G with 5G was written and dropped the same day: the
  owner stays with 3G, 4G, 5G.
- **`State` comes as an int32** from this ModemManager, not a uint32.
- **The Mobile data page said "Failed" while the modem was connected**
  (the owner saw it on 2026-11-27; fixed the same day). The numbers of
  NetworkManager's device state do not run in tens all the way: after
  `IP_CONFIG` (70) come `IP_CHECK` (80), `SECONDARIES` (90), `ACTIVATED`
  (100), `DEACTIVATING` (110) and `FAILED` (120). The first table had
  "Connected" at 80 and "Failed" at 100, and a unit test repeated it. The
  numbers were then read from the typelib of the libnm installed on the
  phone (`NM.DeviceState` and `NM.DeviceStateReason`, through python3-gi),
  and the tables of ModemManager the same way from its library
  (`mm_modem_state_get_string` and the others, through ctypes): all as they
  were. The page now says why a device is unavailable or failed
  ("Failed: the dial was refused"), from `StateReason`.
- **NetworkManager**: `org.freedesktop.NetworkManager.rules` lets an
  active local session of a user in the `sudo` or `netdev` group modify
  system connections, so the Mobile data page needs no privilege. Over
  SSH the same calls are refused, as everywhere here.
- **The file for the next boot** is written by
  `/usr/libexec/cellular-settings-write-modem-mode` through `pkexec`. It
  is sourced as shell code by root once a minute (the redial watchdog calls
  `diting-modem-setup`), so the helper accepts only the four assignments,
  each a word in double quotes, and comments. The polkit action
  `io.github.n3o4po11o.cellular-settings.write-modem-mode` lets the
  desktop session run it without a password; `allow_any` and
  `allow_inactive` are no.
- **A reason is read whole.** An answer longer than a line is shown in a
  dialog, not in a toast: the first version showed "The network mode was
  not taken: org.freedesktop.DBus..." and nothing of what the matter was.
- **GTK warns once per window in Chinese**: "GtkBox ... reported min
  height 51 and natural height 50 in measure()". It is the box of
  libadwaita's view switcher with the labels of that language, one pixel
  out; nothing is cut, and it is not this program's widget.
- **On its side, the phone lost the tabs** (the owner saw it on 2026-11-27).
  The pages were a column in a clamp, with nothing to scroll: a window is
  never smaller than its content, and the Network page made it 906 high,
  where the screen on its side has 610. The tabs under the content were
  below the screen. The pages scroll now, so the window takes the size of
  the screen in any position; and from 500 sp wide a breakpoint moves the
  tabs into the header bar in place of the title (this phone is 305 sp
  upright and 678 on its side). Two mistakes on the way, each seen in a
  picture: `MaxWidth` in a breakpoint means "from the value down", so the
  wide window is `MinWidth`; and a `GtkStack` as the title widget of the
  header bar shows one child, whichever is visible, so the title and the
  tabs are in a `GtkBox`, where visibility is all. Tried on the phone in
  both positions, and on a headless display at 499 and 500 px, where the
  layout changes, and at 678x200, where the whole Network page is in a
  window 200 px high.

## Build

    make cellular-settings

`scripts/build-cellular-settings.sh` builds `cellular-settings_<version>_arm64.deb`
into `output/debs/`, in one of three ways by where it runs:

- in the image of `ci/Dockerfile.cellular-settings`: dpkg-buildpackage right
  there. The image is the Ubuntu suite of the image on arm64 with the
  packages of `config/packages-cellular-settings.list`: that release's own
  GTK 4 and glibc are what the binary is linked against. The cargo target
  directory is kept in `work/`, so a second build compiles what changed.
- on a host with docker: the same, started by `ci/cellular-settings.sh`
  (the subcommands of `ci/ffmpeg.sh`: build, up, down, shell, exec, once,
  make, run, log). `DOCKER="sudo -n docker"` where the user is not in the
  docker group; `REV` names the image without a git checkout.
- without docker, as in the builder of the from-zero build: the arm64
  buildd chroot of the other local packages (`lib-buildd.sh`), with the
  same list of packages.

The crates come from crates.io at build time; `Cargo.lock` is committed.
gtk4 0.11.5 asks for Rust 1.92, and resolute has 1.93.1. Measured on the
phone itself (SM8475, 8 cores) on 2026-11-27, the unit tests included: in
the image, a build from nothing in 189 s and one after a change in the
program's own sources in 47 s; the chroot way from nothing, a debootstrap
of 6 minutes in it, in 10 minutes.

On the phone, as it was done on 2026-11-26:

    # a copy of the tree under ~/k50ultra/diting-ubuntu (no git needed):
    # the phone has no rsync, so tar over ssh
    tar -C diting-ubuntu -cf - ubuntu-diting/Makefile ubuntu-diting/ci \
        ubuntu-diting/config ubuntu-diting/scripts ubuntu-diting/packages/cellular-settings \
        tools/src/nothp.c | ssh ubuntu@172.16.42.1 'tar -C ~/k50ultra/diting-ubuntu -xf -'
    DOCKER="sudo -n docker" REV=dev ubuntu-diting/ci/cellular-settings.sh build
    DOCKER="sudo -n docker" REV=dev ubuntu-diting/ci/cellular-settings.sh make cellular-settings
    DOCKER="sudo -n docker" REV=dev ubuntu-diting/ci/cellular-settings.sh log

Docker Hub answered from the phone at 00:05 on 2026-11-27: `docker pull`
of the base image came back with "Image is up to date" in 3 s. `ci/FFMPEG.md`
has that it did not the day before, and the way for a phone where it does
not (`docker save` there, `docker load` here). The base image needs
`ca-certificates` before cargo can fetch anything: it is in the list. An
instance of the program that is running keeps the old code when the package
is reinstalled: close and reopen it.

## Tests

- `cargo test`, run by the package build: the file of the next boot
  round-trips through the words of `diting-modem-setup`; the presets; the
  settings NetworkManager is given, also when a profile is edited and what
  the form does not name must stay; the answer of `diting-nas-pref`; the
  names of the numbers.
- `ci/tests.sh`, section 14: the helper's `--check` accepts what the
  script reads and refuses everything else. Section 15: which of the three
  ways the build script takes, on a host without docker, with `$DOCKER`
  set or not, and with docker (stand-ins; the image itself is tried on
  the phone). The chroot way ran once where it is meant to, in the ffmpeg
  build container on the phone, which has no docker: the same deb.
- On the phone, 2026-11-26: the helper through pkexec from the desktop
  session writes and deletes; over SSH it is refused. NetworkManager from
  the session adds, changes and deletes a profile. `SetCurrentModes` takes
  3G, 4G, 5G and refuses 4G, 5G.
- `CELLULAR_SETTINGS_SNAPSHOT=DIR/NAME@page cellular-settings` writes the
  window as a PNG and quits: to look at a page without a hand on the
  phone. A window takes a moment to be drawn, and under a locked screen
  the compositor stops showing it after a few seconds: one page per run.
  From the desktop session, so that polkit and the compositor take it for
  a window of the session; on a session bus of its own
  (`dbus-run-session`), so that the window the owner has open is left
  alone.
- `…@page@WIDTHxHEIGHT` after that is the size of the window, on a display
  that lets a window choose it. Phosh does not (it sizes a window itself),
  so the phone was turned to see a page on its side. Broadway, the
  headless display of GTK, does: the program on the phone renders on one
  served by the build container, with its own fonts, locale and modem, at
  any size, and the screen of the owner is not touched. The sizes are in
  pixels at scale 1, the phone's in sp: upright it is 305 wide and on its
  side 678x281. `libgtk-4-bin` is in the package list of the image for it.

        # in the container, once: the server looks for its socket in the
        # cache directory, the program for it in the runtime directory, so both
        # are given the same one, under /src where the phone sees it too
        W=/src/ubuntu-diting/work
        XDG_CACHE_HOME=$W/broadway-cache /usr/bin/gtk4-broadwayd :5 &
        # on the phone, the installed program
        R=$HOME/k50ultra/diting-ubuntu/ubuntu-diting/work/broadway-cache
        dbus-run-session -- env HOME=$HOME XDG_RUNTIME_DIR=$R \
            GDK_BACKEND=broadway BROADWAY_DISPLAY=:5 \
            CELLULAR_SETTINGS_SNAPSHOT=/tmp/shots@network@678x281 cellular-settings

  The first run of this found the two mistakes of the landscape layout
  above, before the phone was turned: a picture at 499 and at 500 px.

Not done on the phone, by a hand: the Apply button as a whole (the NAS
tool, the writing of the file and the two ModemManager calls were each
tried by hand), the Connect button of the Mobile data page, and the form
of a connection.

## Translations

gettext, through the libintl of glibc (`gettext-rs`, `gettext-system`).
Every string is written `t!("...")` in the sources; the catalogs are in
`po/`:

    python3 po/update-pot.py                      # the template, from the sources
    msgmerge -U -N po/zh_CN.po po/cellular-settings.pot
    msgattrib --no-obsolete po/zh_CN.po -o po/zh_CN.po
    msgattrib --untranslated po/zh_CN.po          # what is left to translate
    msgfmt --check -o /dev/null po/zh_CN.po       # has to pass

`-N` keeps msgmerge from guessing: a message whose English changed comes
out untranslated, not fuzzy. A `zh_CN.po~` is left beside the catalog
after a merge; it is not kept.

The catalog is installed as `/usr/share/locale/<lang>/LC_MESSAGES/cellular-settings.mo`
for every `po/*.po`. The interface follows the language of the session; the
locale has to be generated on the phone for it (`sudo locale-gen
zh_CN.UTF-8`), or the catalog is not used. `zh_CN.UTF-8` was generated on
the owner's phone on 2026-11-26.

## Not in it

- 4G and 5G alone (see above).
- A way to disconnect mobile data: `diting-modem-redial` dials the first
  `gsm` connection again within two polls.
- The watchdog applying "EPS only, data-centric" by itself when the
  network refuses the modem: the page says so and the owner chooses.
