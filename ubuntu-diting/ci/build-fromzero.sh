#!/bin/bash
# From-zero build of this tree inside the ci/Dockerfile image, stage by
# stage. Every stage is timed and logged; a failed stage stops the run.
# Nothing here flashes or boots a phone.
#
#   ci/build-fromzero.sh            from zero: work/ and output/ must not exist
#   ci/build-fromzero.sh --resume   continue after the stage that failed
#
# The stages are the documented targets in order (README.md, docs/BUILD.md),
# with sensors, libcamera and phoc between the owner rootfs and the release:
# they build inside a copy of work/rootfs, and `make release` then picks
# their packages up for the public image. `make release` has no Makefile
# prerequisites, so this order is also the only one that works from zero.
#
# Environment: JOBS (parallel builds), FROMZERO_LOGDIR (logs; default
# output/fromzero), RELEASE_PART_SIZE (parts of the release archive,
# default 950MB: below the 1 GB limit of CI job artifacts), STAGES (run only
# the named stages, space separated: to build a package for the phone, for
# example. Every later call then needs --resume, because the tree is no
# longer from zero. DONE appears once all ten stages have passed, also when
# they ran in several calls; ci/run-on-github.sh relies on both).
set -euo pipefail

UD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGDIR="${FROMZERO_LOGDIR:-$UD/output/fromzero}"
STATUS="$LOGDIR/status.tsv"

resume=0
case "${1:-}" in
"") ;;
--resume) resume=1 ;;
*) sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed -n '2,/^$/p' >&2; exit 2 ;;
esac

export RELEASE_PART_SIZE="${RELEASE_PART_SIZE:-950MB}"

all_stages=(
	"check-host:make check-host"
	"sources:make sources"
	"kernel:make kernel"
	"packages:make packages"
	"rootfs:make rootfs"
	"sensors:make sensors"
	"libcamera:make libcamera"
	"phoc:make phoc"
	"release:make release"
	"verify:make verify"
)

stages=("${all_stages[@]}")
if [ -n "${STAGES:-}" ]; then
	stages=()
	for name in $STAGES; do
		found=""
		for s in "${all_stages[@]}"; do
			[ "${s%%:*}" = "$name" ] && found="$s"
		done
		[ -n "$found" ] || { echo "unknown stage '$name'; known: ${all_stages[*]%%:*}" >&2; exit 2; }
		stages+=("$found")
	done
fi

mkdir -p "$LOGDIR"
if [ "$resume" = 0 ]; then
	for d in "$UD/work" "$UD/output"; do
		[ ! -e "$d" ] || { echo "not a from-zero tree: $d exists (remove it, or pass --resume)" >&2; exit 1; }
	done
	rm -f "$STATUS" "$LOGDIR"/*.log "$LOGDIR"/DONE
else
	[ -f "$STATUS" ] || { echo "nothing to resume: no $STATUS" >&2; exit 1; }
fi

cd "$UD"
echo "# from-zero build $(date -u +%FT%TZ): $(git rev-parse HEAD) ($(git rev-parse --abbrev-ref HEAD)), JOBS=${JOBS:-$(nproc)}, $(uname -m), stages: ${STAGES:-all}" | tee -a "$LOGDIR/driver.log"
failed=0
for s in "${stages[@]}"; do
	name="${s%%:*}" cmd="${s#*:}"
	if grep -q -P "^$name\t0\t" "$STATUS" 2>/dev/null; then
		echo "skip $name (done)" | tee -a "$LOGDIR/driver.log"
		continue
	fi
	printf '==> %s: %s\n' "$name" "$cmd" | tee -a "$LOGDIR/driver.log"
	start=$SECONDS
	set +e
	bash -c "$cmd" > "$LOGDIR/$name.log" 2>&1
	rc=$?
	set -e
	secs=$((SECONDS - start))
	printf '%s\t%s\t%s\n' "$name" "$rc" "$secs" >> "$STATUS"
	if [ "$rc" -ne 0 ]; then
		{ echo "FAILED $name (rc=$rc, ${secs}s); last lines of $LOGDIR/$name.log:"; tail -30 "$LOGDIR/$name.log"; } | tee -a "$LOGDIR/driver.log" >&2
		failed=1
		break
	fi
	echo "ok $name (${secs}s)" | tee -a "$LOGDIR/driver.log"
done

# DONE only when every stage of the whole build has passed, also across calls
# that ran a part of it (STAGES).
complete=1
missing=""
for s in "${all_stages[@]}"; do
	if grep -q -P "^${s%%:*}\t0\t" "$STATUS"; then continue; fi
	complete=0
	missing="$missing ${s%%:*}"
done
{
	echo; echo "# stage            rc   seconds"
	awk -F'\t' '{printf "%-18s %s %8d\n", $1, $2, $3}' "$STATUS" 2>/dev/null
	if [ "$failed" != 0 ]; then
		rm -f "$LOGDIR/DONE"
		echo "# stopped at a failed stage; after fixing: ci/build-fromzero.sh --resume"
	elif [ "$complete" = 1 ]; then
		touch "$LOGDIR/DONE"
		echo "# all stages passed; artifacts are host-side checks only (make verify)"
	else
		rm -f "$LOGDIR/DONE"
		echo "# these stages passed; not passed yet:$missing"
	fi
} | tee "$LOGDIR/summary.txt"
[ "$failed" = 0 ]
