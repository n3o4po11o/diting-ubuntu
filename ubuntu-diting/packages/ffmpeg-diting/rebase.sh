#!/bin/bash
# Carry the V4L2 patches of packages/ffmpeg-diting onto a release of FFmpeg.
# The seven in patches/ are liuqin-linux-kit's (userspace/ffmpeg), written for
# the FFmpeg of its own distribution. This applies them to an upstream
# release with `git am -3` - git merges what fits by the blobs named in the
# patches and leaves what does not fit in the tree - and writes the result
# out as a series that applies cleanly. So moving to the next release is
# this script, a look at what it stopped for, and a build.
#
#   packages/ffmpeg-diting/rebase.sh n9.1 /path/to/liuqin-linux-kit/userspace/ffmpeg
#   packages/ffmpeg-diting/rebase.sh n9.2            the series in patches/ onto n9.2
#   packages/ffmpeg-diting/rebase.sh n9.1 --finish   after resolving by hand
#
# In references/ffmpeg (cloned on first use: the history of one release
# branch, without the blobs), step by step:
#   1. fetch the tag and check out the branch ffmpeg-diting/<tag> at it;
#   2. `git am -3` the patches one by one, skipping those already on the
#      branch, and stop at the first that does not apply: the files in
#      conflict are listed. Resolve them, `git add` them, `git am --continue`
#      for the rest, and run this again with --finish (`git am --abort`
#      undoes the one that stopped);
#   3. --finish: `git format-patch` of the branch into
#      work/ffmpeg-rebase/<tag>/, numbered as the files are. Compare with
#      patches/, build (ci/ffmpeg.sh make ffmpeg), and only then copy.
#
# Nothing here writes to patches/ or to the network.
set -euo pipefail

UD="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib.sh
. "$UD/scripts/lib.sh"
need git

usage() {
	sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed -n '/^ *packages\/ffmpeg-diting\/rebase.sh/,/^$/p' >&2
	exit "${1:-1}"
}

finish=0 tag="" from=""
while [ $# -gt 0 ]; do
	case "$1" in
	--finish) finish=1 ;;
	-h | --help) usage 0 ;;
	-*) echo "unknown option: $1" >&2; usage ;;
	*) if [ -z "$tag" ]; then tag="$1"; else from="$1"; fi ;;
	esac
	shift
done
[ -n "$tag" ] || usage
from="${from:-$UD/packages/ffmpeg-diting/patches}"
[ -d "$from" ] || die "no directory of patches: $from"
ls "$from"/*.patch >/dev/null 2>&1 || die "no patches in $from"

dir="$DITING_TOP/references/ffmpeg"
if [ ! -d "$dir/.git" ]; then
	log "cloning FFmpeg $tag: its history without the blobs"
	git clone -q --filter=blob:none --single-branch --branch "$tag" "$FFMPEG_URL" "$dir"
fi
git -C "$dir" cat-file -e "$tag^{commit}" 2>/dev/null ||
	git -C "$dir" fetch -q --filter=blob:none origin "refs/tags/$tag:refs/tags/$tag"

branch="ffmpeg-diting/$tag"
base="$(git -C "$dir" rev-parse "$tag^{commit}")"
cd "$dir"
if ! git rev-parse -q --verify "$branch" >/dev/null; then
	git checkout -q -b "$branch" "$tag"
	log "$tag ($(git rev-parse --short "$base")) on $branch, $(ls "$from"/*.patch | wc -l | tr -d ' ') patch(es) to carry"
fi
[ "$(git rev-parse --abbrev-ref HEAD)" = "$branch" ] ||
	die "references/ffmpeg is on $(git rev-parse --abbrev-ref HEAD), this works on $branch"
[ -z "$(git status --porcelain)" ] || die "references/ffmpeg has changes: nothing started"

if [ "$finish" = 0 ] && [ ! -d .git/rebase-apply ]; then
	# The series goes on in the order of its files, so the commits on the
	# branch are its first n patches: those are skipped when this runs again.
	n=0
	for p in "$from"/*.patch; do
		n=$((n + 1))
		if [ "$n" -le "$(git rev-list --count "$base"..HEAD)" ]; then
			echo "on $branch already: $(basename "$p")"
			continue
		fi
		if git am -3 -q "$p" 2>/dev/null; then
			echo "applied: $(git log -1 --format=%s)"
		else
			echo "STOPPED at $(basename "$p"): $(git stripspace <"$p" | sed -n 's/^Subject: \[PATCH[^]]*\] //p' | tr '\n' ' ')" >&2
			git status --short | grep -E '^(UU|AA|DU|UD|DD|AU|UA|U.|.U)' >&2 || true
			echo "resolve these, git add them, git am --continue, then: $0 $tag --finish" >&2
			exit 1
		fi
	done
fi

[ ! -d .git/rebase-apply ] ||
	die "a patch is still being applied (references/ffmpeg/.git/rebase-apply): resolve it, or git am --abort"

out="$WORK/ffmpeg-rebase/$tag"
rm -rf "$out" && mkdir -p "$out"
git format-patch -q --no-signature --no-numbered -o "$out" "$base"..HEAD
log "$(ls "$out"/*.patch | wc -l | tr -d ' ') patch(es) of $branch against $tag in $out"
echo "compare with packages/ffmpeg-diting/patches and build (ci/ffmpeg.sh make ffmpeg) before copying them there"
