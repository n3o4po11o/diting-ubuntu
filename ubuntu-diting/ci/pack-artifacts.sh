#!/bin/bash
# Collect a finished build (ci/build-fromzero.sh) into a separate directory.
#
#   ci/pack-artifacts.sh DEST [RELEASE_NAME]
#
# DEST gets, each on its own:
#   linux-image-*.deb, boot.img, vendor_boot.img   the small flashable parts
#   rootfs.img.xz.NNN                               the release's sparse rootfs
#                                                   image, xz-compressed, in
#                                                   RELEASE_PART_SIZE parts
#   ubuntu-diting-*.tar.xz.NNN, .SHA256SUMS         the release archive, as
#                                                   `make release` split it
#   owner/                                          the owner image (make
#                                                   owner-release): its boot
#                                                   images and its sparse
#                                                   rootfs image, xz-compressed
#                                                   in parts like the public
#                                                   one; flash-diting.sh; a
#                                                   SHA256SUMS of its own (the
#                                                   workflow makes it an
#                                                   artifact of its own). No
#                                                   SSH key in it: the key is
#                                                   put in after the download,
#                                                   on the machine the artifact
#                                                   goes to (ci/BUILD.md)
#   diting-builder-<rev>.tar.zst                    the builder image (BUILDER_
#                                                   IMAGE_FILE), so the build
#                                                   can be repeated with the
#                                                   same tools (docker load)
#   release-meta/                                   flash script, install guide,
#                                                   package list of the release
#   BUILD-INFO, builder-packages.tsv, stages.txt    what was built, with what,
#                                                   how long each stage took
#   SHA256SUMS                                      of everything else in DEST
#                                                   (owner/ is in its own)
#
# RELEASE_NAME defaults to the newest output/release/ubuntu-diting-*. Read-only
# on output/; needs no docker and no root. Runs inside the builder image (or
# anywhere with xz, split and sha256sum).
#
# Environment: RELEASE_PART_SIZE (default 950MB: below the 1 GB limit of CI
# job artifacts), FROMZERO_LOGDIR (stage logs of the build), and to record
# the builder: BUILDER_IMAGE, BUILDER_IMAGE_ID, BUILDER_PACKAGES (the image's
# /usr/share/diting-builder-packages.tsv), BUILDER_IMAGE_FILE (saved with
# `docker save diting-builder:<rev> | zstd -T0 -10`; linked or copied into
# DEST).
set -euo pipefail

UD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
	sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed -n '2,/^$/p' >&2
	exit 2
fi
export DITING_NOTHP=0			# the host tools need no compiler
export RELEASE_PART_SIZE="${RELEASE_PART_SIZE:-950MB}"
# shellcheck source=../scripts/lib.sh
. "$UD/scripts/lib.sh"			# OUT, KERNEL_*, log/warn/die

mkdir -p "$1"
dest="$(cd "$1" && pwd)" || die "cannot enter $1"
[ -z "$(ls -A "$dest")" ] || die "$dest is not empty: one build per directory"
mkdir -p "$dest/release-meta"

name="${2:-}"
if [ -z "$name" ]; then
	name="$(cd "$OUT/release" && find . -maxdepth 1 -type d -name 'ubuntu-diting-*' -printf '%f\n' | sort | tail -1)"
fi
rel="$OUT/release/$name"
[ -f "$rel/rootfs.img" ] || die "no release $rel (make release first)"
own="$OUT/owner"
[ -f "$own/rootfs.img" ] || die "no owner image $own/rootfs.img (make owner-release)"

log "small flashable parts"
# (not the -dbg package of the same build; same pattern as build-rootfs.sh)
found=0
for d in "$OUT"/debs/linux-image-"$KERNEL_RELEASE"_*-"$KERNEL_DEB_REVISION"_arm64.deb; do
	[ -f "$d" ] && { cp "$d" "$dest/"; found=1; }
done
[ "$found" = 1 ] || die "missing linux-image-$KERNEL_RELEASE deb (make kernel)"
for f in boot.img vendor_boot.img; do
	[ -f "$rel/$f" ] || die "missing $rel/$f"
	cp "$rel/$f" "$dest/"
done
for f in flash-diting.sh INSTALL.md SHA256SUMS BUILD-INFO PACKAGES.tsv; do
	if [ -f "$rel/$f" ]; then cp "$rel/$f" "$dest/release-meta/"; fi
done

log "rootfs.img: xz, in $RELEASE_PART_SIZE parts"
xz -T0 -6 -c "$rel/rootfs.img" | split -b "$RELEASE_PART_SIZE" -d -a 3 - "$dest/rootfs.img.xz."

log "owner image: xz, in $RELEASE_PART_SIZE parts"
mkdir -p "$dest/owner"
for f in boot.img vendor_boot.img BUILD-INFO PACKAGES.tsv; do
	if [ -f "$own/$f" ]; then cp "$own/$f" "$dest/owner/"; fi
done
cp "$UD/release/flash-diting.sh" "$dest/owner/"
xz -T0 -6 -c "$own/rootfs.img" | split -b "$RELEASE_PART_SIZE" -d -a 3 - "$dest/owner/rootfs.img.xz."
# A list of its own: the workflow uploads the owner image as an artifact of
# its own, without DEST's.
(cd "$dest/owner" && find . -type f ! -path ./SHA256SUMS -printf '%P\n' | sort |
	xargs -d '\n' sha256sum > SHA256SUMS)

log "release archive $name"
for f in "$OUT/release/$name".tar.xz* "$OUT/release/$name.SHA256SUMS"; do
	if [ ! -f "$f" ]; then continue; fi
	ln "$f" "$dest/" 2>/dev/null || cp "$f" "$dest/"
done
[ -e "$dest/$name.tar.xz.000" ] || [ -e "$dest/$name.tar.xz" ] ||
	die "no release archive parts for $name"

if [ -n "${BUILDER_PACKAGES:-}" ]; then cp "$BUILDER_PACKAGES" "$dest/builder-packages.tsv"; fi
if [ -n "${BUILDER_IMAGE_FILE:-}" ]; then
	ln "$BUILDER_IMAGE_FILE" "$dest/" 2>/dev/null || cp "$BUILDER_IMAGE_FILE" "$dest/"
fi

{
	echo "git_commit=$(git -C "$UD/.." rev-parse HEAD) ($(git -C "$UD/.." rev-parse --abbrev-ref HEAD))"
	# Changes in the working tree that are not committed (one line per file).
	while IFS= read -r f; do echo "local_change=$(sha256sum "$UD/../$f" | cut -d' ' -f1) $f"; done \
		< <(git -C "$UD/.." ls-files -m -o --exclude-standard)
	echo "kernel=$KERNEL_VERSION ($KERNEL_TAG, commit $KERNEL_COMMIT, signer $KERNEL_TAG_SIGNER_FPR)"
	echo "kernel_release=$KERNEL_RELEASE; patches=$(find "$KERNEL_PATCHES" -name '*.patch' | wc -l); config_fragment=$(sha256_of "$KERNEL_FRAGMENT")"
	echo "ubuntu=$UBUNTU_SUITE from $UBUNTU_MIRROR"
	echo "builder_image=${BUILDER_IMAGE:-none} id=${BUILDER_IMAGE_ID:-none}"
	echo "builder_host=$(uname -srm), $(nproc) cpus"
	if [ -d "$DEVICE_DATA/images" ]; then s="present"; else s="absent (boot image headers not compared with the stock ones)"; fi
	echo "device_data=$DEVICE_DATA: $s"
	echo "device status: UNTESTED ON DEVICE"
} > "$dest/BUILD-INFO"
logs="${FROMZERO_LOGDIR:-$UD/output/fromzero}"
for f in summary.txt status.tsv; do
	if [ -f "$logs/$f" ]; then cp "$logs/$f" "$dest/stages.${f#*.}"; fi
done
for f in MANIFEST.txt MANIFEST.sha256; do
	if [ -f "$OUT/$f" ]; then cp "$OUT/$f" "$dest/build-$f"; fi
done

log "checksums"
# SHA256SUMS is excluded from its own list, and owner/ is not in it: that has
# the list of its own above, which is all there is where the workflow sends it.
# shellcheck disable=SC2094
(cd "$dest" && find . -type f ! -path ./SHA256SUMS ! -path './owner/*' -printf '%P\n' | sort |
	xargs -d '\n' sha256sum > SHA256SUMS && sha256sum -c --quiet SHA256SUMS)
log "artifacts in $dest ($(find "$dest" -type f | wc -l) files, $(du -sh --apparent-size "$dest" | cut -f1))"
