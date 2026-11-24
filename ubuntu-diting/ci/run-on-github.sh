#!/bin/bash
# The build job of .github/workflows/build.yml, run on the runner host: the
# from-zero build of ci/build-fromzero.sh in parts, with what a finished part
# no longer needs deleted before the next one (a hosted runner has little
# disk), then the artifacts of ci/pack-artifacts.sh. Nothing here flashes or
# boots a phone.
#
#   ci/run-on-github.sh LOGDIR STAGEDIR DEST
#
# LOGDIR gets the stage logs, STAGEDIR the saved builder image and DEST
# (which must be new) the artifact directory. The builder image has to exist
# as diting-builder:REV.
#
# Environment: DOCKER (default docker), SUDO (default sudo: the build runs as
# root in the container, so its files belong to root), REV (default: the short
# commit of this tree), JOBS (default: nproc).
set -euo pipefail

UD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOP="$(cd "$UD/.." && pwd)"
if [ $# -ne 3 ]; then
	sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed -n '2,/^$/p' >&2
	exit 2
fi
LOGDIR="$1"
STAGEDIR="$2"
DEST="$3"
DOCKER="${DOCKER:-docker}"
SUDO="${SUDO:-sudo}"
REV="${REV:-$(git -C "$TOP" rev-parse --short HEAD)}"
image="diting-builder:$REV"
export DITING_NOTHP=0			# only the configuration of lib.sh is needed
# shellcheck source=../scripts/lib.sh
. "$UD/scripts/lib.sh"			# OUT, UBUNTU_SUITE, JOBS, log/die

free_gb() { df -BG --output=avail "$1" | tail -1 | tr -dc '0-9'; }

build() { # build [--resume] STAGES...
	local resume=""
	if [ "${1:-}" = --resume ]; then
		resume=--resume
		shift
	fi
	# shellcheck disable=SC2086  # no argument at all when this is not a resume
	"$DOCKER" run --rm --privileged --network=host \
		-v "$TOP:/src" -v "$LOGDIR:/logs" -w /src/ubuntu-diting \
		-e JOBS="$JOBS" -e FROMZERO_LOGDIR=/logs -e STAGES="$*" \
		"$image" ci/build-fromzero.sh $resume
}

drop() { # drop PATH...: what the finished stages no longer need
	local p before
	before="$(free_gb "$TOP")"
	for p in "$@"; do
		case "$p" in
		"$TOP"/*) ;;
		*) die "refusing to delete outside the tree: $p" ;;
		esac
	done
	"$SUDO" rm -rf -- "$@"
	log "deleted: $(printf '%s ' "${@##*/}")  free disk ${before} -> $(free_gb "$TOP") GB"
}

mkdir -p "$LOGDIR" "$STAGEDIR" "$DEST"
log "building $(git -C "$TOP" rev-parse HEAD) with $image, JOBS=$JOBS, free disk $(free_gb "$TOP") GB"

# `make rootfs` runs `make kernel` again as its prerequisite: the kernel tree
# is needed up to here and never after. The owner image is not used either:
# sensors, libcamera and phoc build in the owner rootfs tree (work/rootfs),
# and `make release` makes the public image.
build check-host sources kernel packages rootfs
drop "$UD/work/kernel-src" "$UD/work/kernel-obj" \
	"$OUT/ubuntu-diting-rootfs-$UBUNTU_SUITE-arm64.img"

# Each of the three copies the owner rootfs tree into its own chroot: drop
# it before the next one.
build --resume sensors
drop "$UD/work/sensors-chroot"
build --resume libcamera
drop "$UD/work/libcamera-chroot"
build --resume phoc
# Nothing after this reads the owner tree or the reference trees.
drop "$UD/work/phoc-chroot" "$UD/work/rootfs" "$TOP/references"

build --resume release verify
drop "$UD/work/rootfs-public" "$UD"/work/build-chroot-*
[ -f "$LOGDIR/DONE" ] || die "the build did not pass every stage (see $LOGDIR/summary.txt)"

# The builder image is what makes the build repeatable: the Debian archive
# moves, the saved image does not.
command -v zstd >/dev/null || { "$SUDO" apt-get update -qq && "$SUDO" apt-get install -y -qq --no-install-recommends zstd; }
log "saving $image"
"$DOCKER" save "$image" | zstd -q -T0 -10 -o "$STAGEDIR/diting-builder-$REV.tar.zst"
"$DOCKER" run --rm "$image" cat /usr/share/diting-builder-packages.tsv > "$STAGEDIR/builder-packages.tsv"
image_id="$("$DOCKER" image inspect "$image" --format '{{.Id}}')"

log "packing the artifacts into $DEST"
"$DOCKER" run --rm \
	-v "$TOP:/src" -v "$STAGEDIR:/stage" -v "$LOGDIR:/logs" -v "$DEST:/dest" \
	-w /src/ubuntu-diting \
	-e FROMZERO_LOGDIR=/logs \
	-e BUILDER_IMAGE="$image" -e BUILDER_IMAGE_ID="$image_id" \
	-e BUILDER_PACKAGES=/stage/builder-packages.tsv \
	-e BUILDER_IMAGE_FILE="/stage/diting-builder-$REV.tar.zst" \
	"$image" ci/pack-artifacts.sh /dest

# Everything big that is left is regenerable; the upload needs the space.
drop "$OUT" "$UD/work" "$TOP/kernel/upstream" "$TOP/kernel/.gnupg" "$TOP/references"

log "summary"
cat "$LOGDIR/summary.txt"
log "artifacts in $DEST"
(cd "$DEST" && find . -type f -printf '%12s  %P\n' | sort -k2)
