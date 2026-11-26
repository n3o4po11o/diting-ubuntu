#!/bin/bash
# Build ffmpeg and ffprobe: the FFmpeg release pinned in config/diting.conf
# (its signed tag checked by `fetch-sources.sh --ffmpeg`) with the patches
# of packages/ffmpeg-diting, linked against the libraries of the Ubuntu
# release the rootfs is built from.
#
# It is built in the arm64 buildd chroot of that release (lib-buildd.sh),
# not in the image of the container this runs in: the binaries have to run
# in the rootfs, so they have to be linked against the rootfs's own
# libraries and glibc. The packages the chroot needs are in
# config/packages-ffmpeg.list; the ones the binaries need at run time are
# read off them (ldd) when they are built, and build-rootfs.sh installs
# exactly those in the rootfs.
#
#   make ffmpeg                       (needs sudo, for the chroot)
#   ci/ffmpeg.sh make ffmpeg          in the container, on the phone too
#   ci/ffmpeg.sh make FFMPEG_JOBS=4 ffmpeg     fewer parallel compilers
#
# What is in it (`options`, below): everything FFmpeg has itself, with
# threads; the V4L2 M2M codecs of the iris video core and the DRM device
# context its decoder patches export frames through; and the external
# libraries of general use - https, libx264 and the other codecs, subtitles,
# the usual filters. No other hardware acceleration. --disable-autodetect
# stays, so that nothing slips in that is merely installed in the chroot.
#
# What comes out, in output/ffmpeg/: ffmpeg, ffprobe, runtime-packages.txt
# (the packages the rootfs needs for them) and build-info.txt (the release,
# the patches, the configure line, the compiler and the glibc, every
# package of the chroot with its version, what the binaries list, the
# hashes).
#
# The source is exported and patched on the host and copied into the chroot
# only when the release or the patches changed; it is built out of tree in
# the chroot, configure runs again only when its options or the packages
# did, and a second make compiles what changed.
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/lib-buildd.sh"
need git tar patch

PKG="$UD/packages/ffmpeg-diting"
PKGS="$UD/config/packages-ffmpeg.list"
dir="$DITING_TOP/references/ffmpeg"
git -C "$dir" cat-file -e "$FFMPEG_TAG^{commit}" 2>/dev/null ||
	die "no FFmpeg $FFMPEG_TAG under references/: scripts/fetch-sources.sh --ffmpeg fetches it"
src="$WORK/ffmpeg-src"
out="$OUT/ffmpeg"
csrc=/build/ffmpeg		# the same source, inside the chroot
cobj=/build/ffmpeg-obj
jobs="${FFMPEG_JOBS:-$JOBS}"
mkdir -p "$WORK" "$OUT/logs"

# The options. FFmpeg's own libraries are linked into the two binaries
# (--disable-shared: nothing else uses them); the external libraries are
# the shared ones of the release, named one by one. Threads: with
# --disable-autodetect FFmpeg 9.1 does not turn them on by itself. gpl and
# version3: libx264, libx265, libvidstab and libxvid are under the GPL,
# librubberband and the AMR libraries under a version 3 licence, so the
# binaries are GPL version 2 or later.
# Left out on purpose: every other hardware acceleration (VA-API, OpenCL,
# OpenGL, Vulkan, ...) and what belongs to a desktop or a device (audio
# servers, X11, CD and DVD, plugin systems).
options=(
	--disable-shared
	--enable-static
	--disable-autodetect
	--enable-pthreads
	--enable-gpl
	--enable-version3
	# what a build should have from the system
	--enable-iconv --enable-zlib --enable-bzlib --enable-lzma
	# the hardware: the V4L2 M2M codecs, and the DRM device context
	--enable-v4l2-m2m --enable-libdrm
	# network: https, and SRT
	--enable-openssl --enable-libsrt
	# video and still images
	--enable-libx264 --enable-libx265 --enable-libvpx --enable-libaom --enable-libsvtav1
	--enable-librav1e --enable-libdav1d --enable-libopenjpeg --enable-libtheora --enable-libxvid
	--enable-libwebp --enable-libjxl
	# audio
	--enable-libvorbis --enable-libopus --enable-libmp3lame --enable-libsoxr
	--enable-libopencore-amrnb --enable-libopencore-amrwb
	# subtitles and text, filters
	--enable-libass --enable-libfreetype --enable-libfontconfig --enable-libfribidi --enable-libharfbuzz
	--enable-librubberband --enable-libvidstab --enable-libzimg
	--disable-doc
	--disable-ffplay
	--prefix=/usr
)
packages="$(grep -v '^\s*#' "$PKGS" | sed '/^\s*$/d')"

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

buildd_setup

sudo mkdir -p "$CH/build"
pkgs_digest="$( { cat "$PKGS"; printf '%s\n' "${options[@]}"; } | sha256sum | cut -d' ' -f1)"
if [ "$(sudo cat "$CH/build/.ffmpeg-packages" 2>/dev/null)" != "$pkgs_digest" ]; then
	log "packages of config/packages-ffmpeg.list into the chroot ($(wc -w <<<"$packages" | tr -d ' '))"
	# shellcheck disable=SC2086 # the list is words, one package each
	inch apt-get -y -q install --no-install-recommends $packages >"$OUT/logs/ffmpeg-packages.log" 2>&1 ||
		{ tail -20 "$OUT/logs/ffmpeg-packages.log"; die "installing the packages failed (log: $OUT/logs/ffmpeg-packages.log)"; }
	echo "$pkgs_digest" | sudo tee "$CH/build/.ffmpeg-packages" >/dev/null
fi
if [ "$(sudo cat "$CH/build/.ffmpeg-source" 2>/dev/null)" != "$digest" ]; then
	sudo rm -rf "$CH$csrc" && sudo mkdir -p "$CH$csrc"
	sudo tar -C "$src" -cf - . | sudo tar --no-same-owner -C "$CH$csrc" -xf -
	echo "$digest" | sudo tee "$CH/build/.ffmpeg-source" >/dev/null
fi

if [ "$(sudo cat "$CH$cobj/config.options" 2>/dev/null)" != "${options[*]}" ] || [ ! -f "$CH$cobj/config.mak" ]; then
	log "configuring"
	sudo mkdir -p "$CH$cobj"
	printf '%s\n' "${options[*]}" | sudo tee "$CH$cobj/config.options" >/dev/null
	inch sh -ec "cd $cobj && $csrc/configure ${options[*]}" >"$OUT/logs/ffmpeg-configure.log" 2>&1 ||
		{ grep -n -i -E "error|not found|unknown option" "$OUT/logs/ffmpeg-configure.log" | head -20; tail -5 "$OUT/logs/ffmpeg-configure.log"
		die "configure failed (log: $OUT/logs/ffmpeg-configure.log)"; }
fi

log "building ffmpeg and ffprobe in the chroot, $jobs in parallel"
inch sh -ec "cd $cobj && make -j$jobs ffmpeg ffprobe" >"$OUT/logs/ffmpeg-build.log" 2>&1 ||
	{ grep -n -E "error|Error|undefined reference" "$OUT/logs/ffmpeg-build.log" | head -20; tail -5 "$OUT/logs/ffmpeg-build.log"
	die "make failed (log: $OUT/logs/ffmpeg-build.log)"; }

rm -rf "$out" && mkdir -p "$out"
for b in ffmpeg ffprobe; do
	sudo cp "$CH$cobj/$b" "$out/$b"
	sudo chown "$(id -u):$(id -g)" "$out/$b" 2>/dev/null || true
	chmod 755 "$out/$b"
	inch file "$cobj/$b" | grep -q "ELF 64-bit LSB.*AARCH64\|ELF 64-bit LSB.*aarch64" ||
		die "$b is not an arm64 executable: $(inch file "$cobj/$b" | cut -c1-160)"
done
# What the binaries need at run time, as packages of the release: every
# shared object ldd resolves for them, and the package that owns it. ldd
# lines are of two kinds: "libx.so => /path/libx.so (0x…)" and
# "/lib/ld-linux-aarch64.so.1 (0x…)"; "linux-vdso.so.1 (0x…)" has no path.
sudo tee "$CH/build/ffmpeg-runtime-packages" >/dev/null <<'R'
{ ldd ./ffmpeg; ldd ./ffprobe; } | awk '/=> \//{print $3} /^ \/[^ ]/{print $1}' | sort -u |
	xargs -r dpkg -S | cut -d: -f1 | sort -u
R
inch sh -ec "cd $cobj && sh /build/ffmpeg-runtime-packages" >"$out/runtime-packages.txt" ||
	die "could not read the packages of the libraries the binaries need"
[ -s "$out/runtime-packages.txt" ] || die "no packages read off the binaries"
# What this build is for, read back from the binaries: the V4L2 M2M codecs
# the patches are about, and what was asked for besides them. (ffmpeg lists
# one kind per call: -encoders and -decoders on one line shows only one of
# them. The listing is read into a variable first: with pipefail, a grep -q
# that stops at the first match leaves ffmpeg a broken pipe, and the check
# fails.)
for c in "encoders h264_v4l2m2m" "encoders hevc_v4l2m2m" "decoders h264_v4l2m2m" \
	"decoders hevc_v4l2m2m" "decoders vp9_v4l2m2m" "hwaccels drm" \
	"encoders libx264" "encoders libx265" "encoders libvpx-vp9" "encoders libsvtav1" \
	"decoders libdav1d" "protocols https" "protocols srt" "filters subtitles" \
	"filters drawtext" "filters zscale"; do
	listing="$(inch "$cobj/ffmpeg" -hide_banner "-${c%% *}" 2>/dev/null)"
	grep -q "${c##* }" <<<"$listing" ||
		die "ffmpeg lists no ${c##* } among its ${c%% *}: configure left it out"
done
# the lines of a listing are the entries (the header is the only line that
# does not start with a space); count_codec counts the entries with a name
count() { inch "$cobj/ffmpeg" -hide_banner "-$1" 2>/dev/null | grep -c '^ ' || true; }
count_codec() { inch "$cobj/ffmpeg" -hide_banner "-$1" 2>/dev/null | grep -c "$2" || true; }
{
	echo "FFmpeg $FFMPEG_TAG, commit $(git -C "$dir" rev-parse "$FFMPEG_TAG^{commit}")"
	for p in "$PKG"/patches/*.patch; do echo "patch $(basename "$p")"; done
	echo "configure: ${options[*]}"
	echo "compiler: $(inch sh -c 'gcc --version | head -1')"
	echo "glibc: $(inch sh -c 'ldd --version | head -1' | grep -o 'GLIBC [0-9.]*') (that of $UBUNTU_SUITE: built in its arm64 buildd chroot, linked against its libraries)"
	echo "license: $(inch "$cobj/ffmpeg" -L 2>&1 | grep -m1 'General Public' | sed 's/^ *//')"
	echo "encoders $(count encoders), decoders $(count decoders), demuxers $(count demuxers), muxers $(count muxers), filters $(count filters)"
	echo "V4L2 M2M codecs: $(count_codec encoders v4l2m2m) encoders, $(count_codec decoders v4l2m2m) decoders"
	echo "hardware acceleration methods: $(inch "$cobj/ffmpeg" -hide_banner -hwaccels 2>/dev/null | sed 1d | tr -s ' \n' ' ')"
	echo "warnings in the build log: $(grep -c 'warning:' "$OUT/logs/ffmpeg-build.log")"
	echo "packages of the chroot:"
	# shellcheck disable=SC2086 # the list is words, one package each
	inch dpkg-query -W -f='  ${Package} ${Version}\n' $packages
	echo "packages the binaries need at run time ($(wc -l <"$out/runtime-packages.txt" | tr -d ' ')): $(tr '\n' ' ' <"$out/runtime-packages.txt")"
	(cd "$out" && sha256sum ffmpeg ffprobe)
} >"$out/build-info.txt"
log "wrote $out/ffmpeg, ffprobe (linked against the libraries of $UBUNTU_SUITE; runtime-packages.txt and build-info.txt have the rest)"
