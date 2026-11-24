#!/bin/bash
# For the build job of .github/workflows/build.yml, after its last stage:
# saves the builder image and packs the artifacts of ci/pack-artifacts.sh, as
# steps 3 and 4 of ci/BUILD.md. Runs on the runner host. Nothing here flashes
# or boots a phone.
#
#   ci/run-pack.sh STAGEDIR DEST
#
# STAGEDIR takes the saved builder image; DEST (which must be new) is the
# artifact directory. Every stage has to have passed first: DONE has to be
# in ubuntu-diting/output/fromzero.
#
# Environment: DOCKER (default docker), REV (the short commit; the builder
# image is diting-builder:REV), FROMZERO_LOGDIR (default
# ubuntu-diting/output/fromzero).
set -euo pipefail

UD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOP="$(cd "$UD/.." && pwd)"
if [ $# -ne 2 ]; then
	sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed -n '2,/^$/p' >&2
	exit 2
fi
STAGEDIR="$1"
DEST="$2"
DOCKER="${DOCKER:-docker}"
REV="${REV:-$(git -C "$TOP" rev-parse --short HEAD)}"
image="diting-builder:$REV"
LOGDIR="${FROMZERO_LOGDIR:-$UD/output/fromzero}"
log() { printf '==> %s\n' "$*" >&2; }

[ -f "$LOGDIR/DONE" ] || { echo "not every stage passed, so there is nothing to pack (see $LOGDIR/summary.txt)" >&2; exit 1; }
command -v zstd >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq --no-install-recommends zstd; }
mkdir -p "$STAGEDIR" "$DEST"

# The builder image is what makes the build repeatable: the Debian archive
# moves, the saved image does not.
log "saving $image"
"$DOCKER" save "$image" | zstd -q -T0 -10 -o "$STAGEDIR/diting-builder-$REV.tar.zst"
"$DOCKER" run --rm "$image" cat /usr/share/diting-builder-packages.tsv >"$STAGEDIR/builder-packages.tsv"
image_id="$("$DOCKER" image inspect "$image" --format '{{.Id}}')"

log "packing the artifacts into $DEST"
"$DOCKER" run --rm \
	-v "$TOP:/src" -v "$STAGEDIR:/stage" -v "$DEST:/dest" -w /src/ubuntu-diting \
	-e BUILDER_IMAGE="$image" -e BUILDER_IMAGE_ID="$image_id" \
	-e BUILDER_PACKAGES=/stage/builder-packages.tsv \
	-e BUILDER_IMAGE_FILE="/stage/diting-builder-$REV.tar.zst" \
	"$image" ci/pack-artifacts.sh /dest

log "summary"
cat "$LOGDIR/summary.txt"
log "artifacts in $DEST"
(cd "$DEST" && find . -type f -printf '%12s  %P\n' | sort -k2)
