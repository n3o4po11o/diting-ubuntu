# The FFmpeg container

For the FFmpeg of `packages/ffmpeg-diting` nothing has to be installed on
the host that builds it - not on the build server, and not on the phone the
binaries are tried on, whose own packages stay as they are. The toolchain is
an image, `ci/Dockerfile.ffmpeg`, and `ci/ffmpeg.sh` drives it, as
`ci/kernel.sh` does the kernel. What comes out is two statically linked
binaries, `ffmpeg` and `ffprobe`: the phone runs them, and nothing else.

```sh
export DOCKER="sudo -n docker"     # where this user is not in the docker group: the phone
REV=…                              # only without a git checkout (a partial tree on the phone)
ubuntu-diting/ci/ffmpeg.sh build            # the image for this checkout: diting-ffmpeg:<rev>
ubuntu-diting/ci/ffmpeg.sh up               # the container diting-ffmpeg, the checkout at /src
ubuntu-diting/ci/ffmpeg.sh make ffmpeg      # fetch, patch, build: in tmux inside the container
ubuntu-diting/ci/ffmpeg.sh log              # the end of the last command and EXIT=<status>
ubuntu-diting/ci/ffmpeg.sh shell            # a bash in the container, as the same user
ubuntu-diting/ci/ffmpeg.sh down
```

The container mechanics are those of `ci/KERNEL.md` (the checkout at `/src`,
`make` in the tmux session `k50ultra-ffmpeg`, `run` in `k50ultra-ffmpeg-run`,
the output in `output/logs/make-<target>.log`). What differs is the image,
and that the phone itself is a build host: see "On the phone".

## What `make ffmpeg` builds

**FFmpeg n9.1** ("Gauss", released 2026-11-20: the newest release on
ffmpeg.org when `FFMPEG_TAG` was set on 2026-11-26), locked the way the
kernel is, in `config/diting.conf`: `FFMPEG_URL`, `FFMPEG_TAG`, the commit
the tag points at, and the key it is signed with.
`scripts/fetch-sources.sh --ffmpeg` clones the tag and checks both against
`config/keyrings/ffmpeg-release.asc`, the release manager's key that is in
the tree - not one from a keyserver.

**Seven patches**, `packages/ffmpeg-diting/patches/`: the V4L2 work of
liuqin-linux-kit for the same SoC, carried onto n9.1 as they are (see "The
patches", below).

| patch | what it fixes |
| --- | --- |
| 0001 | the encoder negotiates its input buffer for the height padded to 32 (736 lines for 720): copy the visible rows only, the chroma after the padded luma. The stock ffmpeg copies 736 rows out of a 720-row frame, past its end, and crashes at random (KNOWN_ISSUES, "Video encoding") |
| 0002 | the decoder's visible rectangle without S_SELECTION, which the stateful Iris decoder rejects |
| 0003 | encoded packets detached before the capture buffer goes back: the last frame of a stream was lost |
| 0004 | the visible crop read again on every SOURCE_CHANGE event |
| 0005 | decoder frames exported as DRM PRIME (linear NV12/NV21 DMA-BUF) |
| 0006 | decoder PTS carried through positive timestamp cookies (negative ones came out as 4294 s) |
| 0007 | the decoder session reopened after a flush |

**No external library but libdrm** (`--disable-autodetect`), linked
statically, so that a change to the image cannot leak into the result:
the binaries need nothing from the system they run on. Two things are named
in the options because configure counts them with what it autodetects:
`--enable-v4l2-m2m` (the `*_v4l2m2m` encoders and decoders, the point of
the build) and `--enable-libdrm` (the DRM device context the command line
needs for the DRM PRIME frames). VA-API is left out: it loads libva at run
time, and the browser path has the phone's own ffmpeg.

The script refuses a result without the V4L2 codecs: the first build on
2026-11-26 had none, and nothing in it said so.

**What comes out**, in `output/ffmpeg-static/`: `ffmpeg`, `ffprobe`
(statically linked; the script checks), and `build-info.txt` with the
release, the patches, the configure line, the compiler and the hashes. The
build is out of tree in `work/ffmpeg-obj`: a second run compiles what
changed.

## The patches, and the next release

The seven are liuqin-linux-kit's `userspace/ffmpeg/0001`–`0007` (kit 0a91067),
written for the FFmpeg of its own distribution. They apply to n9.1 as they
are - `git am -3` took each without a conflict - and the files in `patches/`
are what that wrote: the kit's diffs with the blob ids of n9.1, under the
kit's file names. When FFmpeg has a new release:

```sh
# in the tree, with references/ffmpeg (cloned on first use) and the kit at hand
packages/ffmpeg-diting/rebase.sh n9.2 /path/to/liuqin-linux-kit/userspace/ffmpeg
# or, to carry this package's own series on:
packages/ffmpeg-diting/rebase.sh n9.2
```

It checks the tag out on the branch `ffmpeg-diting/<tag>` of
`references/ffmpeg`, applies the series one patch at a time, and stops at
the first that does not fit: the files in conflict are listed. Resolve
them, `git add` them, `git am --continue`, then `rebase.sh <tag> --finish`
writes the series to `work/ffmpeg-rebase/<tag>/`. Build before copying the
files into `patches/`, and set `FFMPEG_TAG`, `FFMPEG_COMMIT` and the key in
`config/diting.conf` together. The script runs anywhere (also on a Mac:
`scripts/lib.sh` compiles nothing there).

## The image

The base image is the one of `ci/Dockerfile` and `ci/Dockerfile.kernel`,
pinned by digest. `/usr/share/diting-ffmpeg-packages.tsv` in the image
lists what it contains.

| Role | Debian packages |
| --- | --- |
| Compile: `scripts/build-ffmpeg.sh` | `build-essential`, `libdrm-dev` (the one library linked in), `pkg-config` (configure looks libdrm up with it), `file` (the check that the result is static) |
| Fetch and verify: `fetch-sources.sh --ffmpeg` | `git`, `gnupg`, `ca-certificates` |
| The series | `patch` |
| Inside the container | `sudo` (the scripts call it; as root it asks for nothing), `tmux` (what `ci/ffmpeg.sh make` runs in), `less`, `vim-tiny` |

## On the phone

The phone is where the result is tried, so it is the one build host that
builds on arm64 without emulation - and the one that must not be changed
by it. Read there on 2026-11-26:

- **Docker is on the phone** (29.10), and `ubuntu` is not in the docker
  group: `DOCKER="sudo -n docker"`. The host has no compiler, and gets none:
  `gcc`, `make` and `pkg-config` were absent before and after.
- **Docker Hub is not reachable from the phone** (`registry-1.docker.io`
  answers nothing). The base image was there already, pulled three weeks
  earlier with the digest this tree pins (`debian@sha256:a72b4433…`), so
  `FROM debian:trixie-slim@sha256:…` resolves locally. On a phone without
  it: `docker save` the image on the build server and `docker load` it there.
- **apt works inside the build** (`deb.debian.org`, 1.3 s for an `InRelease`
  from the phone). The image takes 93–119 s there.
- **The tree on the phone is a partial one**, what the build needs, copied
  from the Mac as files (no `.git`), into `~/k50ultra/diting-ubuntu-driver-fix/`:
  `ubuntu-diting/{Makefile,ci/{ffmpeg.sh,Dockerfile.ffmpeg,diting-kernel-entrypoint,
  diting-kernel-make},scripts/{lib.sh,fetch-sources.sh,build-ffmpeg.sh},
  config/,packages/ffmpeg-diting/}` and `tools/src/nothp.c`. Without a git
  checkout `ci/ffmpeg.sh` names the image by `REV`.
- **The clone was cut once** on the way (`curl 56 … early EOF`; a clone
  cannot resume): `fetch-sources.sh` starts it over, three times at most.
- **What it takes there, with `FFMPEG_JOBS=6`** (the phone has eight cores,
  and other things to do): the clone with the check of the tag 12 s;
  configure 21 s; 2096 objects in 5 min 31 s to the two linked binaries.
  A run that changes nothing is over in seconds.
- The binaries run on the host as they are: `file` says statically linked,
  `ldd` says not a dynamic executable, and `ffmpeg -version` prints 9.1.
- **To remove it all**: `ci/ffmpeg.sh down`, `sudo docker rmi
  diting-ffmpeg:<rev>`, and the tree under `~/k50ultra/`.

## Read on the phone with it (2026-11-26)

On driver-fix with 0119–0135, with the build above (`ffmpeg`
`4f01664172a56a73…`, `ffprobe` `abe2000fad95108f…`). The reference is the
phone's own ffmpeg 8.0.1: it writes the test clips in software, decodes
what the new one encodes, and stands next to it on the decoding side. The
clips are 720p, 1080p and 4K, 150 frames, H.264, HEVC and VP9, from
`testsrc2`. The script is kept as `tests/ff-final.sh` of
`release/driver-fix-batch5/` (outside this tree), its output as
`logs/ffmpeg-final-on-0135.txt` there.

| what | result |
| --- | --- |
| decoding against software | 7 of 7 identical, every frame (per-frame sha256): H.264 and HEVC at 720p, 1080p and 4K; VP9 at 720p |
| encoding, the input not padded | 24 of 24 streams complete (H.264 and HEVC; 720p, 1080p, 854x480, 4K; 60 frames), the visible size as asked (720, not 736). PSNR against the source: 47.7 / 48.5 dB at 720p, 44.4 / 44.2 at 1080p, 48.7 / 48.6 at 854x480, 38.5 / 38.8 at 4K |
| the last frames | 1 to 200 frames asked, at 17 counts in and around the groups of pictures: exactly that many pictures in the stream, both codecs |
| a long tail | two encoders at once, 900 frames each, three rounds, and one encoder alone, three rounds: 900 every time. Next to it, the phone's own ffmpeg with the input padded lost the last 2 to 5 frames in 7 of 80 runs of 60 frames |
| DRM PRIME output | `-hwaccel drm -hwaccel_output_format drm_prime`, read back: 5 of 5 identical to software; to a null sink with nothing read back, 3 files three times, 150 frames each |
| timestamps | streams with B-frames, four files: the pts of every frame as software gives them, none unknown |
| flush and reopen | one decoder, the same file three times in a row (concat): 450 frames, identical to software, 5 of 5; two seeks in one process: identical |
| kernel log | nothing from iris, the SMMU or videobuf2 through all of it; the core suspends when idle |

The phone's own ffmpeg keeps its place: Firefox, GStreamer's `libav`
plugin and the rest use its libraries. The new binaries are tried by
running them; nothing on the phone calls them by itself.

## Not in it

- **A package for the rootfs.** This is the build to try the patches on the
  phone; how they get into the image is a decision of its own. The way a
  local package is made here is `scripts/build-libva-v4l2-stateful.sh`
  (upstream plus patches, in the arm64 buildd chroot). What has to be
  decided first: the phone's own ffmpeg is 8.0.1, whose libraries
  (`libavcodec62`, `libavformat62`, …) are linked by Firefox's ffmpeg
  backend, `gstreamer1.0-libav`, `ffmpegthumbnailer` and `scrcpy`; 9.1 has
  other names for them, so a 9.1 package goes in next to it (and reaches
  only what is started with it), while an 8.0.3 package could replace the
  archive's - if the series applies there as cleanly.
