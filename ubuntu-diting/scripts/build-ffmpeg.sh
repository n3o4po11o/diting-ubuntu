#!/bin/bash
# Build static ffmpeg and ffprobe: the FFmpeg release pinned in
# config/diting.conf (its signed tag checked by `fetch-sources.sh --ffmpeg`)
# with the patches of packages/ffmpeg-diting, and not one external library
# (--disable-autodetect). The binaries need nothing from the system they run
# on: this is the build to try the V4L2 patches on the phone itself, whose
# own packages stay as they are. ci/ffmpeg.sh makes the image with the
# toolchain and runs this in it (ci/FFMPEG.md).
#
#   ci/ffmpeg.sh make ffmpeg          on the build server, or on the phone
#   ci/ffmpeg.sh make FFMPEG_JOBS=4 ffmpeg     fewer parallel compilers
#
# What comes out, in output/ffmpeg-static/: ffmpeg, ffprobe and
# build-info.txt (the release, the patches, the configure line, the compiler,
# the hashes).
#
# It builds out of tree in work/ffmpeg-obj: the source is exported and
# patched again only when the release or the patches changed, configure runs
# again only when its options did, and a second make compiles what changed.
. "$(dirname "$0")/lib.sh"
need git tar patch gcc make file

PKG="$UD/packages/ffmpeg-diting"
dir="$DITING_TOP/references/ffmpeg"
git -C "$dir" cat-file -e "$FFMPEG_TAG^{commit}" 2>/dev/null ||
	die "no FFmpeg $FFMPEG_TAG under references/: scripts/fetch-sources.sh --ffmpeg fetches it"
src="$WORK/ffmpeg-src"
obj="$WORK/ffmpeg-obj"
out="$OUT/ffmpeg-static"
mkdir -p "$WORK" "$OUT/logs" "$obj"

# The options: what FFmpeg has itself, linked statically, and one library of
# the image, libdrm, for the DRM device context that the ffmpeg command line
# needs to ask for the DRM PRIME frames the decoder patches export
# (-hwaccel drm). Everything else configure would look for on the system is
# turned off, so a change to the image cannot leak into the result. The V4L2
# encoders and decoders (h264_v4l2m2m, ...) are part of FFmpeg, but
# configure counts them with the hardware accelerators it autodetects, so
# they are named here; VA-API is left out on purpose, it loads libva at run
# time.
options=(
	--disable-shared
	--enable-static
	--extra-ldflags=-static
	--disable-autodetect
	--enable-v4l2-m2m
	--enable-libdrm
	--disable-doc
	--prefix=/usr
)

digest="$({ git -C "$dir" rev-parse "$FFMPEG_TAG^{commit}"; cat "$PKG"/patches/*.patch; } | sha256sum | cut -d' ' -f1)"
if [ "$(cat "$WORK/ffmpeg-src.digest" 2>/dev/null)" != "$digest" ]; then
	log "exporting FFmpeg $FFMPEG_TAG and applying $(ls "$PKG"/patches/*.patch | wc -l | tr -d ' ') patch(es)"
	rm -rf "$src" && mkdir -p "$src"
	git -C "$dir" archive --format=tar "$FFMPEG_TAG" | tar -x -C "$src"
	for p in "$PKG"/patches/*.patch; do
		patch -p1 -d "$src" --quiet --no-backup-if-mismatch <"$p" ||
			die "$(basename "$p") does not apply to FFmpeg $FFMPEG_TAG (packages/ffmpeg-diting/rebase.sh carries the series on)"
	done
	echo "$digest" >"$WORK/ffmpeg-src.digest"
fi

if [ "$(cat "$obj/config.options" 2>/dev/null)" != "${options[*]}" ] || [ ! -f "$obj/config.mak" ]; then
	log "configuring"
	printf '%s\n' "${options[*]}" >"$obj/config.options"
	( cd "$obj" && "$src/configure" "${options[@]}" ) >"$OUT/logs/ffmpeg-configure.log" 2>&1 ||
		{ tail -20 "$OUT/logs/ffmpeg-configure.log"; die "configure failed (log: $OUT/logs/ffmpeg-configure.log)"; }
fi

log "building ffmpeg and ffprobe in $obj, ${FFMPEG_JOBS:-$JOBS} in parallel"
( cd "$obj" && make -j"${FFMPEG_JOBS:-$JOBS}" ffmpeg ffprobe ) >"$OUT/logs/ffmpeg-build.log" 2>&1 ||
	{ grep -n -E "error|Error" "$OUT/logs/ffmpeg-build.log" | head -20; tail -5 "$OUT/logs/ffmpeg-build.log"; die "make failed (log: $OUT/logs/ffmpeg-build.log)"; }

rm -rf "$out" && mkdir -p "$out"
for b in ffmpeg ffprobe; do
	cp "$obj/$b" "$out/$b"
	file "$out/$b" | grep -q "statically linked" ||
		die "$b is not statically linked: $(file -b "$out/$b")"
done
# What this build is for: the V4L2 M2M codecs the patches are about. (A first
# build on 2026-11-26 had none, and nothing in it said so.) ffmpeg lists one
# kind per call: -encoders and -decoders on one line shows only one of them.
# The listing is read into a variable first: with pipefail, a grep -q that
# stops at the first match leaves ffmpeg a broken pipe, and the check fails.
for c in "encoders h264_v4l2m2m" "encoders hevc_v4l2m2m" "decoders h264_v4l2m2m" \
	"decoders hevc_v4l2m2m" "decoders vp9_v4l2m2m" "hwaccels drm"; do
	listing="$("$out/ffmpeg" -hide_banner "-${c%% *}" 2>/dev/null)"
	grep -q "${c##* }" <<<"$listing" ||
		die "$out/ffmpeg lists no ${c##* } among its ${c%% *}: configure left it out"
done
{
	echo "FFmpeg $FFMPEG_TAG, commit $(git -C "$dir" rev-parse "$FFMPEG_TAG^{commit}")"
	for p in "$PKG"/patches/*.patch; do echo "patch $(basename "$p")"; done
	echo "configure: ${options[*]}"
	echo "compiler: $(gcc --version | head -1)"
	echo "V4L2 M2M codecs: $(grep -c v4l2m2m <<<"$( "$out/ffmpeg" -hide_banner -encoders 2>/dev/null)") encoders, $(grep -c v4l2m2m <<<"$( "$out/ffmpeg" -hide_banner -decoders 2>/dev/null)") decoders"
	echo "hardware acceleration methods: $( "$out/ffmpeg" -hide_banner -hwaccels 2>/dev/null | sed 1d | tr -s ' \n' ' ')"
	echo "warnings in the build log: $(grep -c 'warning:' "$OUT/logs/ffmpeg-build.log")"
	(cd "$out" && sha256sum ffmpeg ffprobe)
} >"$out/build-info.txt"
log "wrote $out/ffmpeg, ffprobe (statically linked; build-info.txt has the rest)"
