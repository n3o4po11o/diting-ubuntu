# The FFmpeg build

`make ffmpeg` builds two binaries, `ffmpeg` and `ffprobe`: FFmpeg n9.1
with the V4L2 patches of `packages/ffmpeg-diting`, linked against the
libraries of the Ubuntu release the rootfs is built from, with the
external libraries of general use. Every rootfs of this tree has them in
`/usr/local/bin` (below). Nothing has to be installed on the host for it:
on a host without the tools, `ci/Dockerfile.ffmpeg` is the image and
`ci/ffmpeg.sh` drives it, as `ci/kernel.sh` does the kernel - on the phone
itself too, whose own packages stay as they are.

```sh
make ffmpeg                                 # needs sudo: the build chroot
export DOCKER="sudo -n docker"              # where this user is not in the docker group: the phone
REV=…                                       # only without a git checkout (a partial tree on the phone)
ubuntu-diting/ci/ffmpeg.sh build            # the image for this checkout: diting-ffmpeg:<rev>
ubuntu-diting/ci/ffmpeg.sh up               # the container diting-ffmpeg, privileged, the checkout at /src
ubuntu-diting/ci/ffmpeg.sh make ffmpeg      # fetch, patch, build: in tmux inside the container
ubuntu-diting/ci/ffmpeg.sh log              # the end of the last command and EXIT=<status>
ubuntu-diting/ci/ffmpeg.sh shell            # a bash in the container, as the same user
ubuntu-diting/ci/ffmpeg.sh down
```

The container mechanics are those of `ci/KERNEL.md` (the checkout at
`/src`, `make` in the tmux session `k50ultra-ffmpeg`, the output in
`output/logs/make-<target>.log`). What differs is the image, and that the
container is **privileged**: the build chroot binds `/proc`, `/sys` and
`/dev` into itself.

## What is in it

**FFmpeg n9.1** ("Gauss", released 2026-11-20: the newest release on
ffmpeg.org when `FFMPEG_TAG` was set on 2026-11-26), locked the way the
kernel is, in `config/diting.conf`: `FFMPEG_URL`, `FFMPEG_TAG`, the commit
the tag points at, and the key it is signed with.
`scripts/fetch-sources.sh --ffmpeg` clones the tag and checks both against
`config/keyrings/ffmpeg-release.asc`, the release manager's key that is in
the tree - not one from a keyserver.

**Seven patches**, `packages/ffmpeg-diting/patches/`: the V4L2 work of
liuqin-linux-kit for the same SoC, carried onto n9.1 as they are (see "The
patches, and the next release", below).

| patch | what it fixes |
| --- | --- |
| 0001 | the encoder negotiates its input buffer for the height padded to 32 (736 lines for 720): copy the visible rows only, the chroma after the padded luma. The stock ffmpeg copies 736 rows out of a 720-row frame, past its end, and crashes at random (KNOWN_ISSUES, "Video encoding") |
| 0002 | the decoder's visible rectangle without S_SELECTION, which the stateful Iris decoder rejects |
| 0003 | encoded packets detached before the capture buffer goes back: the last frame of a stream was lost |
| 0004 | the visible crop read again on every SOURCE_CHANGE event |
| 0005 | decoder frames exported as DRM PRIME (linear NV12/NV21 DMA-BUF) |
| 0006 | decoder PTS carried through positive timestamp cookies (negative ones came out as 4294 s) |
| 0007 | the decoder session reopened after a flush |

**The options** are the `options` of `scripts/build-ffmpeg.sh`, every
external library named. The decision they follow is the owner's
(2026-11-27): the hardware video codecs of this phone and nothing else of
hardware, and everything else of common use.

| | what |
| --- | --- |
| FFmpeg's own | every codec, demuxer, muxer and filter FFmpeg has, with threads (`--enable-pthreads`: with `--disable-autodetect`, FFmpeg 9.1 does not turn them on by itself) |
| The hardware | the V4L2 M2M codecs of the iris video core (`h264_v4l2m2m`, `hevc_v4l2m2m` to encode; H.264, HEVC and VP9 to decode) and the DRM device context (`--enable-libdrm`), which the decoder patches export DMA-BUF frames through (`-hwaccel drm`) |
| Network | `https` and the other TLS protocols (OpenSSL); SRT |
| Video | libx264, libx265, libvpx (VP8, VP9), libaom, SVT-AV1 and rav1e (AV1), dav1d (AV1 decoding), openjpeg (JPEG 2000), Theora, XviD; WebP and JPEG XL |
| Audio | Vorbis, Opus, MP3 (LAME), the SoX resampler, AMR narrowband and wideband |
| Subtitles and text | libass (`subtitles` filter); `drawtext` with fontconfig, FriBidi and HarfBuzz |
| Filters | rubberband (time stretching), vidstab (stabilisation), zimg (`zscale`) |
| From the system | iconv, zlib, bzip2, LZMA |
| Not in it, on purpose | every other hardware acceleration (VA-API, OpenCL, OpenGL, Vulkan, ...), and what belongs to a desktop or a device: audio servers (PulseAudio, JACK, ALSA), X11 capture, CD and DVD, Samba, plugin systems (frei0r, LADSPA, LV2) |

`--disable-autodetect` stays in front of all that: a package that turns up
in the build chroot changes nothing unless it is named. The binaries are
GPL version 2 or later (libx264, libx265, libvidstab and libxvid are under
the GPL; librubberband and the AMR libraries under a version 3 licence).

**What comes out**, in `output/ffmpeg/`: `ffmpeg`, `ffprobe`,
`runtime-packages.txt` (the packages of the release whose libraries the
two binaries load: read off them with `ldd` when they are built) and
`build-info.txt` (the release, the patches, the configure line, the
compiler and the glibc, every package of the build chroot with its
version, what the binaries list, the hashes).

## Where it is built, and why there

In the **arm64 buildd chroot of the Ubuntu suite**, the one
`lib-buildd.sh` makes for the other local packages
(`work/build-chroot-resolute-arm64`: debootstrap'ed from the archive the
rootfs comes from) - not in the image of the container, which is Debian 13.
The binaries are linked against the shared libraries of that release, so
they run in the rootfs, where the same packages are installed: that is
what the rootfs is. (Against Debian 13's libraries they would not: other
versions, other names.)

The packages the chroot needs are in `config/packages-ffmpeg.list`, one
line per purpose. In the from-zero build (`ci/BUILD.md`) the chroot is
there anyway for the VA-API driver and the others, and `make rootfs`
depends on `make ffmpeg`.

A second run is cheap: the source is exported and patched on the host and
copied into the chroot only when the release or the patches changed; the
packages are installed only when the list or the options changed; it is
built out of tree, so configure runs again only then, and a second make
compiles what changed.

On another architecture than arm64 the chroot runs under qemu-user, like
the other builds of that chroot; that has not been tried for this one.

Why not statically linked, as the first build of 2026-11-26 was: Ubuntu
26.04 ships no static library for many of these (libx264 among them,
dav1d, SVT-AV1, HarfBuzz and its whole stack of text), so static would
have meant building each of those from source - and the rootfs is ours,
where the shared libraries are there anyway (the owner, 2026-11-27).

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

## In the rootfs

`make rootfs` depends on `make ffmpeg`, and `scripts/build-rootfs.sh`:

1. installs the packages of `runtime-packages.txt`, so that every library
   the two binaries load is there whatever the package lists of the image
   contain;
2. copies the two binaries into `/usr/local/bin/` of every rootfs the tree
   builds, the owner image and the public one. They are files, not a
   package: dpkg does not know them, and `/etc/diting-build` says which
   FFmpeg they are;
3. runs both once in the rootfs (`ffmpeg -version`, `ffprobe -version`):
   a library that is missing shows there, before the image is made.

`/usr/local/bin` comes before `/usr/bin` on every PATH - a user's shell,
a systemd service - so `ffmpeg` and `ffprobe` on the command line are
these. (A program that sets its own PATH without `/usr/local/bin` gets the
archive's.) That is wanted - the archive's 8.0.1 crashes on input the
encoder does not pad and loses the tail of a stream - and it has a price: this build has nothing of the desktop and the
device in it that the archive's has (no PulseAudio or ALSA capture, no X11
capture, for example). The archive's ffmpeg stays at `/usr/bin/ffmpeg` for
whatever calls it by that path; what links its libraries (Firefox's
backend, GStreamer's `libav` plugin, ffmpegthumbnailer) is not affected,
since they use the libraries, not these files.

`make verify` checks that the two files are in the rootfs image, that
`ffmpeg` is an arm64 executable and the one `make ffmpeg` built, and that
every package of `runtime-packages.txt` is installed in the image.

## On the phone

The phone is where the result is tried, so it is the one build host that
builds on arm64 without emulation - and the one that must not be changed
by it. Read there on 2026-11-26 and 27:

- **Docker is on the phone** (29.10), and `ubuntu` is not in the docker
  group: `DOCKER="sudo -n docker"`. The host has no compiler and gets none:
  `gcc`, `make` and `pkg-config` were absent before and after.
- **Docker Hub is not reachable from the phone**. The base image was there
  already, pulled earlier with the digest this tree pins
  (`debian@sha256:a72b4433…`), so `FROM debian:trixie-slim@sha256:…`
  resolves locally. On a phone without it: `docker save` the image on the
  build server and `docker load` it there. That was not always so: at 00:05
  on 2026-11-27 `docker pull ubuntu:26.04@sha256:d66b366d…` was answered
  from the registry in 3 s ("Image is up to date", the image of
  `ci/Dockerfile.cellular-settings`), which is what that Dockerfile counts
  on. What differed the day before was not looked into; `docker load`
  stays the way for a phone that cannot.
- **apt works inside the build**: `deb.debian.org` for the image (25–55 s),
  `ports.ubuntu.com` for the build chroot (its debootstrap took 14 minutes
  there on 2026-11-26, one package at a time).
- **A tree on the phone is a copy of files**, not a git checkout unless
  `.git` was copied too: then set `REV`, and `ci/ffmpeg.sh` names the image
  by it.
- **The clone was cut once** on the way (`curl 56 … early EOF`; a clone
  cannot resume): `fetch-sources.sh` starts it over, three times at most.
- **To remove it all**: `ci/ffmpeg.sh down`, `sudo docker rmi
  diting-ffmpeg:<rev>`, `sudo rm -rf` the tree (parts of `work/` are
  root's: the chroot).

## Read on the phone with it

### 2026-11-27: this build

Built on the phone as above (`ffmpeg` `a8a46dd62cb9fd8b…`), on the kernel of
driver-fix with 0130–0135. **Run in the build chroot**: on the phone's own
system, as it is until an image with this build is flashed, one library is
missing (`libsrt.so.1.5`, which the archive's ffmpeg there does not pull
in). The chroot has every package of `runtime-packages.txt`, so it is the
rootfs to come; the archive's ffmpeg 8.0.1, Noto Sans CJK and curl were put
into it for the reference. The scripts are in
`liuqin-study/tmp/iris-msgs/ff-v2{,b,c,d,e}.sh` of the session.

| what | result |
| --- | --- |
| what it lists | 208 encoders, 541 decoders, 372 demuxers, 194 muxers, 491 filters, 69 protocols; `-threads`; GPL version 3 or later (librubberband and the AMR libraries). Not listed: VA-API, OpenCL, any hardware acceleration but `drm` |
| https | a 10 s clip (1 MB) from test-videos.co.uk, over TLS and from the file it was saved to: 300 frames identical. A file that does not exist: `HTTP error 404`. A clip on github.com (795 frames, through its redirect): one of two attempts was reset by the network, the other read all of it |
| software encoders, 60 frames of 1080p, decoded back by the archive's ffmpeg | libx264 44.9 dB (2.6 s), libx265 41.4 dB (2.7 s), mpeg4 47.4 dB; libvpx-vp9, libsvtav1, librav1e and libaom-av1 at their usual quality settings 30.4 dB each (17.7 s, 4.6 s, 19.4 s, 88 s at `-cpu-used 4`; libaom at 10.7 s for 30 frames of 720p at `-cpu-used 8`). Animated WebP |
| threads | x264 of those 60 frames: 2979 ms at 1 thread, 1735 ms at 4; the software H.264 decode of them 430 ms and 307 ms; of the 4K clip 2901 ms at 1 thread, 1484 ms at 6 |
| audio | 10 s of a tone and noise as Opus, Vorbis, MP3, AAC, FLAC, PCM and AMR-NB: every one decoded back by the archive's ffmpeg; the tone is all of the Opus file's power at 440 Hz. The SoX resampler, rubberband and vidstab run without an error |
| subtitles and text | a subtitle file in GBK, in GB18030 and in Big5 read as UTF-8, correctly (and refused when declared as the wrong set). A GBK file burned in with libass and Noto Sans CJK - the frame was looked at. `drawtext` with a font by name, and with Chinese, shaped by HarfBuzz |
| zscale | as with the archive's own ffmpeg, tried next to it: it converts when the input's colour properties are all named, and answers "no path between colorspaces" otherwise |
| the V4L2 patches | as on 2026-11-26, every number of it: decoding 7 of 7 identical to software, encoding with the input not padded 24 of 24 (the same PSNR to the sixth decimal), the last frames exact, DRM PRIME 5 of 5, timestamps 4 of 4, flush and reopen 5 of 5, seeks 3 of 3; nothing in the kernel log; the core suspends when idle |

### 2026-11-26: the first build

That one was a small static build: `--disable-autodetect` with only libdrm
and the V4L2 codecs named, so without threads, without `https`, without any
external codec. It is what showed the patches work; the numbers are of the
kernel of driver-fix with 0130–0135 (`ffmpeg` `4f01664172a56a73…`), with the
phone's own ffmpeg 8.0.1 as the reference: it writes the test clips in
software, decodes what the new one encodes, and stands next to it on the
decoding side. The clips are 720p, 1080p and 4K, 150 frames, H.264, HEVC
and VP9, from `testsrc2`. The script is kept as `tests/ff-final.sh` of
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
