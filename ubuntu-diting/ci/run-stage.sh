#!/bin/bash
# One call of ci/build-fromzero.sh in the container: a step of the build job
# of .github/workflows/build.yml, which is one step per stage, so that the
# log of a step is the log of that stage, live. Runs on the runner host.
# Nothing here flashes or boots a phone.
#
#   ci/run-stage.sh          check-host sources   the first step: from zero
#   ci/run-stage.sh --resume kernel               every later step
#
# Environment: DOCKER (default docker), REV (the short commit; the builder
# image is diting-builder:REV), JOBS (default: nproc).
set -euo pipefail

UD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOP="$(cd "$UD/.." && pwd)"
DOCKER="${DOCKER:-docker}"
REV="${REV:-$(git -C "$TOP" rev-parse --short HEAD)}"
resume=""
if [ "${1:-}" = --resume ]; then
	resume=--resume
	shift
fi
if [ $# -eq 0 ]; then
	sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed -n '2,/^$/p' >&2
	exit 2
fi

printf '==> diting-builder:%s on %s, stages: %s, free disk %s GB\n' "$REV" "$(uname -m)" "$*" \
	"$(df -BG --output=avail "$TOP" | tail -1 | tr -dc '0-9')"
# --init: a cancelled job reaches the driver as SIGTERM (without an init
# process, PID 1 of the container ignores it), and the driver then stops the
# processes of the running stage.
# shellcheck disable=SC2086  # no argument at all when this is not a resume
"$DOCKER" run --rm --init --privileged --network=host \
	-v "$TOP:/src" -w /src/ubuntu-diting \
	-e JOBS="${JOBS:-$(nproc)}" -e STAGES="$*" \
	"diting-builder:$REV" ci/build-fromzero.sh $resume
