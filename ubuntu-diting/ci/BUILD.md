# Build from zero in a container

Everything this tree builds can be built from zero inside one container: the
kernel, the packages, the owner rootfs, the packages that need a rootfs, the
public release and the owner image. Every stage is timed and logged, and the
results are packed for upload. The container comes from `Dockerfile` in this
directory, so the tools do not depend on the host and a build can be repeated
later. Nothing here flashes or boots a phone.

The host needs only Docker, a checkout of this tree and network access (and
`zstd` to save the image). GitHub Actions runs the same steps (see GitHub
Actions, below). The reference run (2026-11-24, 2 h 32 min) is described at
the end.

## Files

| File | Purpose |
| --- | --- |
| `Dockerfile` | The builder image: Debian 13 with the host packages of `docs/BUILD.md` and what the scripts need in a container. The base image is pinned by digest. |
| `build-fromzero.sh` | Runs the build stage by stage: times each stage, prints what it prints as it runs and a progress line every minute, stops at the first failure, resumes after it. |
| `pack-artifacts.sh` | Collects a finished build into one directory: the flashable parts, the rootfs image, the release archive, the builder image, checksums. |
| `lint.sh` | What the lint job of the workflow runs: shellcheck over the shell scripts; an error fails. |
| `tests.sh` | Tests of the scripts in this directory against stand-ins for make and docker; seconds inside the image. |
| `run-stage.sh` | For the workflow: one call of the driver in the container, so that a step of the workflow is a stage. |
| `run-pack.sh` | For the workflow, after its last stage: saves the builder image and packs the artifacts (steps 3 and 4). |

## What it needs

- **A privileged container.** `build-rootfs.sh` and the package chroots
  bind-mount `/proc`, `/sys` and `/dev` and chroot into them. A privileged
  container can reach the host's devices, so build a tree you trust; nothing
  in the scripts writes outside `work/`, `output/` and the source clones.
- **Network.** git.kernel.org (kernel tree and the tag signer's keys),
  GitHub, gitlab.freedesktop.org, gitlab.postmarketos.org and codeberg.org
  (reference trees), ports.ubuntu.com, packages.mozilla.org and the snap
  store. `--network=host` gives the container the host's resolver.
- **Disk.** About 65 GB for one run (source clones 6.5 GB, `work/` 41 GB,
  `output/` 15 GB) plus 3.8 GB for the packed artifacts. The owner image
  (`owner-release`, added after the reference run) should cost about what the
  public `rootfs.img` costs in both places, 4.5 GB and 1.8 GB; not measured
  yet.
- **Time.** Hours; see the stage table. Start the run detached.
- **No phone data.** `device-data/` is not needed. Without it the header
  comparison against the stock boot images is skipped (`build-release.sh`
  says so with a warning).

## Procedure

Run from the root of the checkout. `REV` is the commit being built; the image
tag and the artifact names carry it.

### 1. Build the image

```sh
REV=$(git rev-parse --short HEAD)
docker build -t diting-builder:$REV --build-arg VCS_REF=$(git rev-parse HEAD) ubuntu-diting/ci
```

Inside the image, `/usr/share/diting-builder-packages.tsv` lists every package
in it with its version.

### 2. Build from zero

```sh
mkdir -p /tmp/diting-logs
docker run -d --name diting-fromzero --init --privileged --network=host \
    -v "$PWD:/src" -v /tmp/diting-logs:/logs -w /src/ubuntu-diting \
    -e JOBS=6 -e FROMZERO_LOGDIR=/logs \
    diting-builder:$REV ci/build-fromzero.sh
```

The script refuses to start when `ubuntu-diting/work` or `ubuntu-diting/output`
exists: from zero means a fresh checkout. The container runs as root, so
`work/`, `output/` and the cloned trees end up owned by root on the host.
Watch it with `docker logs -f diting-fromzero`. What comes out:

- What the stage prints, as it runs (also kept in `/tmp/diting-logs/<stage>.log`).
- Once a minute: how long the stage has been running, the free disk, and for
  every log under `output/logs` that is being written to (that is where the
  build scripts keep the compiler's and the package builds' output) its
  number of lines and its last line.
- When a stage fails: the last 40 lines of each of those logs.

`status.tsv` gets one line per stage with its exit status and seconds,
`driver.log` the short version of the output, and `DONE` appears when all
stages have passed. The container exits when the run ends, with the build's
exit status; `docker stop` stops the processes of the running stage too.

If a stage fails, fix the cause, remove the container (`docker rm
diting-fromzero`) and run the same command with `ci/build-fromzero.sh
--resume` at the end: stages that passed are skipped.

`JOBS` is the parallelism of the kernel build. The reference run used 6 on a
host with 8 cores and 10 GB RAM that was in use at the same time.

To build only some stages, name them in `STAGES`, space separated:
`-e STAGES="sources packages verify"` gives the device package and the checks
of it in a few minutes, for a package to try on the phone. Every later call
on the same tree then needs `--resume`. `DONE` appears only once all eleven
stages have passed, also when they ran in several calls.

### 3. Save the builder image

The image is what makes the build repeatable: the Debian archive moves, the
saved image does not. This needs Docker and `zstd` on the host.

```sh
mkdir -p /tmp/diting-stage
docker save diting-builder:$REV | zstd -T0 -10 > /tmp/diting-stage/diting-builder-$REV.tar.zst
docker run --rm diting-builder:$REV cat /usr/share/diting-builder-packages.tsv \
    > /tmp/diting-stage/builder-packages.tsv
```

### 4. Pack the artifacts

Back inside the image. `DEST` is an absolute path on the host and must not
exist or be empty: one build per directory. It should be on the same
filesystem as `output/`, then the release parts are hard-linked instead of
copied. The xz compression of the rootfs image took about 15 minutes on the
reference host.

```sh
docker run --rm \
    -v "$PWD:/src" -v /tmp/diting-stage:/stage -v /tmp/diting-logs:/logs \
    -v "$DEST:/dest" -w /src/ubuntu-diting \
    -e FROMZERO_LOGDIR=/logs \
    -e BUILDER_IMAGE=diting-builder:$REV \
    -e BUILDER_IMAGE_ID="$(docker image inspect -f '{{.Id}}' diting-builder:$REV)" \
    -e BUILDER_PACKAGES=/stage/builder-packages.tsv \
    -e BUILDER_IMAGE_FILE=/stage/diting-builder-$REV.tar.zst \
    diting-builder:$REV ci/pack-artifacts.sh /dest
```

### 5. Copy and check

`DEST` is self-contained: copy the directory wherever artifacts are kept and
check it there. The directory on the other host has to exist. `owner/` has
the `SHA256SUMS` of its own, so it is checked on its own.

```sh
name=$(basename "$DEST")
tar -C "$(dirname "$DEST")" -cf - "$name" | ssh USER@HOST 'tar -C ~/incoming -xf -'
ssh USER@HOST "cd ~/incoming/$name && sha256sum -c --quiet SHA256SUMS && echo OK"
ssh USER@HOST "cd ~/incoming/$name/owner && sha256sum -c --quiet SHA256SUMS && echo OK"
```

## Stages

These are the documented targets, in the only order that works from zero.
The last column is the reference run.

| Stage | Target | What it builds | Time |
| --- | --- | --- | --- |
| `check-host` | `make check-host` | Host tools present. | < 1 s |
| `sources` | `make sources` | The signed kernel tag, its signature verified, and the reference trees at their pinned commits. | 10 min |
| `kernel` | `make kernel` | Export, the kernel patches, Image, DTBs, modules, the `linux-image` package. | 49 min |
| `packages` | `make packages` | `device-xiaomi-diting`, fastrpc, hexagonrpcd. | 41 s |
| `rootfs` | `make rootfs` | Its prerequisites first (VA-API driver, firmware-setup, mobile-config-firefox, ModemManager, phosh, each in an arm64 build chroot), then the owner rootfs and its image. | 40 min |
| `sensors` | `make sensors` | libssc and iio-sensor-proxy with SSC support. | 3 min |
| `libcamera` | `make libcamera` | Ubuntu's libcamera with the diting patches. | 14 min |
| `phoc` | `make phoc` | Ubuntu's phoc with the diting patch. | 4 min |
| `release` | `make release` | The public rootfs with every local package, the sparse image, the release archive in 950 MB parts. | 29 min |
| `owner-release` | `make owner-release` | The owner rootfs built again, from zero and with every local package: locked account, no SSH key. Its boot images and sparse image in `output/owner/`. | not in the reference run |
| `verify` | `make verify` | Host-side checks of the kernel, packages and rootfs. | 2 min |

Why this order:

- `make release` has no Makefile prerequisites. Called first, it stops with
  `missing .../linux-image-*.deb; run 'make kernel packages' first`.
- `sensors`, `libcamera` and `phoc` compile inside a copy of `work/rootfs`,
  the owner rootfs, so they have to follow `make rootfs`.
- `make rootfs` does not depend on those three: it only warns when their
  packages are missing. An image built with `make rootfs` alone has no
  patched libcamera, no sensor clients and no patched phoc. `make release`
  and `make owner-release` pick their packages up, because they are in
  `output/debs` by then.
- `owner-release` follows the three for that reason, and it replaces
  `work/rootfs`: the driver passes `FORCE_ROOTFS=1`, so the owner rootfs of
  the image is built from zero. It comes after `release` because the public
  image is the one everything else is for.

## Artifacts

One directory, `diting-main-<rev>-<date>` in the reference run. The sizes are
those of that run.

```
linux-image-7.2.10-diting_7.2.10-52_arm64.deb   39.5 MB
boot.img                                       54,050,816 bytes
vendor_boot.img                                20,807,680 bytes
rootfs.img.xz.000, rootfs.img.xz.001           950,000,000 + 874,103,800 bytes
ubuntu-diting-<date>.tar.xz.000, .001          950,000,000 + 908,065,032 bytes
ubuntu-diting-<date>.SHA256SUMS
owner/                                         not in the reference run: see The owner image
diting-builder-<rev>.tar.zst                   214 MB
release-meta/                                  flash script, install guide, package list
BUILD-INFO                                     commit, kernel, builder image
builder-packages.tsv                           the packages in the builder image
stages.txt, stages.tsv                         result and seconds of every stage
build-MANIFEST.txt, build-MANIFEST.sha256      what `make verify` checked
SHA256SUMS                                     of everything above but owner/
```

- The three small files are the parts that get flashed or installed on their
  own: the kernel package, the boot image with the kernel, the vendor_boot
  image with the device tree and the initramfs.
- `rootfs.img.xz.*` is the public rootfs as the sparse image that
  `flash-diting.sh` writes to userdata (4.5 GB uncompressed), xz-compressed.
  Reassemble with `cat rootfs.img.xz.* | xz -dc > rootfs.img`.
- `ubuntu-diting-<date>.tar.xz.*` is the release archive as `make release`
  splits it: boot images, sparse rootfs, flash script, install guide.
- One part is 950 MB = 950,000,000 bytes, below the 1 GB limit of CI job
  artifacts.
- `diting-builder-<rev>.tar.zst` is the builder image (`zstd -dc … | docker
  load`), so the same tools can be used again however the archives have moved.

### The owner image

`owner/` is the image for the owner of a phone, from the `owner-release`
stage: every local package; the boot images made inside its own rootfs, with
`diting.debug=usb` on the kernel command line as in every owner build; the
account locked, `sudo` without a password.

```
owner/boot.img, vendor_boot.img
owner/rootfs.img.xz.000, .001                  the sparse rootfs image, xz-compressed
owner/flash-diting.sh
owner/BUILD-INFO, PACKAGES.tsv
owner/SHA256SUMS                               of the owner/ files: on GitHub it is an artifact of its own
```

The image has no SSH key: the runner has none to put in, so both rootfs
stages end with `WARN: no SSH public key installed`. sshd accepts keys only,
and a locked account cannot unlock the screen either, so the image cannot be
logged in to as it is.

Putting the key in is a local step, on the Linux machine the artifact was
downloaded to, with `ubuntu-diting/release/add-ssh-key.sh` of a checkout of
this tree: `docs/OWNER_IMAGE.md` has it, step by step. The workflow neither
runs that script nor ships it. Nothing of the step runs as root on the
machine or mounts anything there: the work is done in a container, and in
the container the image is never mounted (its files are written with
`debugfs`, and `e2fsck` checks the filesystem before and after).

## Reference run

2026-11-24, 08:31 to 11:03 UTC, on a diting phone itself: SM8475, 8 cores,
10 GB RAM, Ubuntu 26.04, Docker 29.10.0. Nothing else was on the host; the
build tools all came from the image.

- Tree: `main` at 095e359 plus this directory and the fix of the libcamera
  patch 0005, uncommitted at the time. `BUILD-INFO` lists their SHA-256.
- Image: `diting-builder:095e359`, ID
  `sha256:6658cd60690d075860889c375a9bb56ba92788e112b86470012e09c5159e2286`,
  921 MB, 284 packages. Base image, pinned in the Dockerfile:
  `debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2`.
  To build with exactly these tools, load the saved image instead of
  rebuilding the Dockerfile.
- All ten stages passed in one go. The kernel build had no compiler crash and
  no retry. Memory available to the host never dropped below 5.7 GB in the
  progress snapshots; the CPU reached 73 °C.
- `make verify`: 32 checks, all passed, one skipped (below).
- The public image has 1217 packages, 22 of them local builds.
- The artifacts (21 files, 3.8 GB) are in
  `~/k50ultra/incoming/diting-main-095e359-20261124/` on the build server,
  where `sha256sum -c SHA256SUMS` passes. They are also kept, with the logs,
  under `/home/ubuntu/work/` on the phone.
- Device status: **UNTESTED ON DEVICE**. Nothing of this build was flashed.

## GitHub Actions

`.github/workflows/build.yml` has two jobs.

- **lint**, on every push and pull request, on a hosted x86-64 runner, in
  under two minutes: builds the image, runs `ci/lint.sh` (shellcheck, an
  error fails) and `ci/tests.sh` (the tests of the scripts in this
  directory).
- **build**, after lint: on pushes to main, on tags `v*`, weekly (Mondays
  03:23 UTC) and by hand, on a hosted arm64 runner (`ubuntu-24.04-arm`,
  free for public repositories), which is the native build of this page:
  the eleven stages of the table above, one step per stage (the first two
  together), through `ci/run-stage.sh`; then `ci/run-pack.sh` saves the
  image and packs the artifacts. Three workflow artifacts come out, kept for
  14 days: `diting-<rev>` (the directory of the Artifacts section without
  `owner/`), `diting-<rev>-owner` (`owner/`, about 1.9 GB) and
  `diting-<rev>-logs`.

The log of a step is what the driver prints for its stage, live: the output
of the stage, the progress line every minute, and when it fails the end of
the build logs it wrote and an error annotation in the summary of the run.
The `...-logs` artifact has the logs of the stages and those of the build
scripts (`output/logs`), whether the build passed or not.

The build of a new push to main replaces the build of the commit before it:
the second run was cancelled that way, ten minutes into its rootfs stage,
when the next commit was pushed. Commits that only change documentation or
the experimental patches start nothing. To build on a self-hosted runner
instead, set the repository variable `BUILD_RUNNER` to its label.

Measured on a hosted runner, which has four cores: 115 GB free once the
workflow has removed the preinstalled SDKs (one unbroken run needs about 65
GB), `sources` 4 minutes, `kernel` 28 minutes, `packages` 21 seconds. A
hosted runner stops a job after 6 hours; the job's timeout is 350 minutes.

Not verified at the time of writing. On GitHub, the stages from `rootfs` on
and the packing have not completed (the first run to reach them was the one
that got cancelled), a cancellation stopping the processes of the running
stage is tested with stand-ins only, and so are the two upload steps that
make `owner/` an artifact of its own. The `owner-release` stage has not run
from zero anywhere: `build-owner-release.sh` and the packing were run on an
owner image built on 2026-11-21, and on a 10 GB image with 770 MB of real
files in it.

`add-ssh-key.sh` is in two halves, and they are not verified alike. The
half that runs in the container has run with the real tools (the debugfs,
e2fsck, simg2img and xz of Debian 13) as a normal user on a host, on the
small images of `ci/tests.sh` (section 12) and on that 10 GB image: after
the change `e2fsck` is clean, and three 4 KB blocks of the image differ
from before. The half that runs on the host, which is the docker call, has
run only against the stand-in for docker: with a real docker it has not
run, and no real artifact of the workflow has gone through the script. An
image it made has not been flashed.

## What building from zero showed

A clean checkout of `main` at 095e359 did not get through unaided.

Fixed in this tree:

1. **The libcamera patch 0005 could not be applied.** The copy committed in
   82fdd82 had two source lines joined into one in its first hunk, so
   `make libcamera` stopped at `Patch … 0005 … does not apply`. The build that
   was verified on the phone on 2026-11-22 used a different copy, generated
   at 19:53; the commit had the older draft of 19:23. The patch is now that
   verified copy.
2. **`build-essential` is required.** The kernel compiled, then `bindeb-pkg`
   stopped: `unmet build dependencies: build-essential:native`. On a host
   with a dpkg database the kernel package's dependencies are checked, and
   the separate `gcc` and `make` of the `docs/BUILD.md` list do not satisfy
   them. The image installs `build-essential`.

Still open in the tree; this flow works around them by running the targets
itself:

3. **`make release` has no prerequisites** (above).
4. **`make verify` does not check the release's boot images.** Its boot-image
   section looks at host-built images in `output/boot`, which the release
   flow does not produce, so it is skipped (`no boot images built`) and 32
   instead of 35 checks run. The ramdisk check added for the 2026-11-23 boot
   hang is among those that do not run. Checked by hand on the reference
   run: the release's initramfs has `e2fsck`, `fsck`, `logsave` and both
   `diting-debug` scripts, and the header of `vendor_boot.img` matches
   `config/diting.conf`.
5. **`make lint` fails.** `packages/device-xiaomi-diting/src/*` in the
   `lint` target includes four Python programs, which shellcheck rejects
   (SC1071). `ci/lint.sh` is what the workflow runs instead: the same files,
   with the shell scripts told by their shebang. Over the whole tree
   shellcheck 0.10.0 reports one more error, outside those files: `SC2045`
   in `packages/device-xiaomi-diting/debian/postinst`.
6. **`make image` is not the release.** It builds boot images for the
   initramfs-only debug mode by default (`BOOT_MODE=debug`), and the owner
   image. That is why this flow ends with `make release`.

Not verified:

- The Dockerfile's branch for other architectures (cross toolchain and
  qemu-user) builds: the lint job does it on x86-64. No build has run in
  that image; only the native arm64 path has.
- The build repeats in configuration, not bit for bit: the Ubuntu archive,
  the `libcamera` and `phoc` sources (`apt-get source` without a version) and
  the snap store move.
