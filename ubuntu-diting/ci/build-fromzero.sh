#!/bin/bash
# From-zero build of this tree inside the ci/Dockerfile image, stage by
# stage. Every stage is timed; a failed stage stops the run. Nothing here
# flashes or boots a phone.
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
# What gets printed while the build runs:
#   - the output of the stage as it comes (also kept in <logdir>/<stage>.log)
#   - once a minute: the elapsed time, the free disk, and for every log
#     under output/logs that is being written to (the build scripts keep the
#     compiler's and dpkg's output there, not on standard output) its number
#     of lines and its last line
#   - when a stage fails: the last 40 lines of each of those logs, and an
#     error annotation for GitHub Actions
# One line per stage of all this is in <logdir>/driver.log.
#
# A cancelled run (SIGTERM, SIGINT) stops the processes of the running stage
# too and exits with 130.
#
# Environment: JOBS (parallel builds), FROMZERO_LOGDIR (logs; default
# output/fromzero), RELEASE_PART_SIZE (parts of the release archive,
# default 950MB: below the 1 GB limit of CI job artifacts), STAGES (run only
# the named stages, space separated: to build a package for the phone, for
# example. Every later call then needs --resume, because the tree is no
# longer from zero. DONE appears once all ten stages have passed, also when
# they ran in several calls; .github/workflows/build.yml relies on both),
# FROMZERO_HEARTBEAT (seconds between the progress lines, default 60).
set -euo pipefail

UD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGDIR="${FROMZERO_LOGDIR:-$UD/output/fromzero}"
STATUS="$LOGDIR/status.tsv"
heartbeat="${FROMZERO_HEARTBEAT:-60}"
if ! [ "$heartbeat" -gt 0 ] 2>/dev/null; then
	echo "FROMZERO_HEARTBEAT must be a number of seconds, not '$heartbeat'" >&2
	exit 2
fi

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

# The guard comes before the log directory is made: with the default log
# directory, under output/, making it first would fail the guard.
if [ "$resume" = 0 ]; then
	for d in "$UD/work" "$UD/output"; do
		[ ! -e "$d" ] || { echo "not a from-zero tree: $d exists (remove it, or pass --resume)" >&2; exit 1; }
	done
	rm -f "$STATUS" "$LOGDIR"/*.log "$LOGDIR"/DONE
else
	[ -f "$STATUS" ] || { echo "nothing to resume: no $STATUS" >&2; exit 1; }
fi
mkdir -p "$LOGDIR"

cd "$UD"

# ---- running one stage
stage_pid="" sleeper="" stream_pid="" name="" stage_start=0 stage_rc=0

stopped() { # a cancelled run: do not leave the processes of the stage running
	echo "cancelled while the stage '$name' was running" >&2
	[ -z "$sleeper" ] || kill "$sleeper" 2>/dev/null || true
	[ -z "$stream_pid" ] || kill "$stream_pid" 2>/dev/null || true
	[ -z "$stage_pid" ] || kill -- "-$stage_pid" 2>/dev/null || true
	exit 130
}
trap stopped TERM INT

log_state() { # modification time and name of every log under output/logs
	local f
	for f in "$UD"/output/logs/*; do
		if [ -f "$f" ]; then printf '%s %s\n' "$(stat -c %Y "$f")" "$f"; fi
	done
	return 0
}
stage_logs() { # the logs under output/logs that changed since log_state
	local f
	for f in "$UD"/output/logs/*; do
		if [ -f "$f" ] && ! grep -qxF "$(stat -c %Y "$f") $f" "$LOGDIR/.logs"; then
			echo "$f"
		fi
	done
	return 0
}
progress() { # one line for the stage, and one per log it is writing to
	local f now
	now=$(date +%s)
	printf '[%s: %dm, %s free]\n' "$name" "$(((SECONDS - stage_start) / 60))" \
		"$(df -h --output=avail "$UD" | tail -1 | tr -d ' ')"
	while read -r f; do
		# only what was written to in the last two intervals
		if [ "$(stat -c %Y "$f")" -ge $((now - heartbeat * 2)) ]; then
			printf '    %s: %s lines, last: %s\n' "${f##*/}" "$(wc -l <"$f")" "$(tail -n 1 "$f" | cut -c1-150)"
		fi
	done < <(stage_logs)
}

run_stage() { # run_stage NAME COMMAND: the exit status lands in stage_rc
	local waited=0
	name="$1"
	stage_start=$SECONDS
	log_state >"$LOGDIR/.logs"
	: >"$LOGDIR/$name.log"
	# The stage leads its own process group, so that a cancellation reaches
	# all of its processes, the compiler included.
	setsid bash -c "$2" >"$LOGDIR/$name.log" 2>&1 &
	stage_pid=$!
	tail -n +1 -f "$LOGDIR/$name.log" &
	stream_pid=$!
	while kill -0 "$stage_pid" 2>/dev/null; do
		# A sleep that is waited for: the trap above runs at once, not after
		# the sleep.
		sleep 1 &
		sleeper=$!
		wait "$sleeper" || true
		sleeper=""
		waited=$((waited + 1))
		if [ $((waited % heartbeat)) -eq 0 ] && kill -0 "$stage_pid" 2>/dev/null; then
			progress
		fi
	done
	stage_rc=0
	wait "$stage_pid" || stage_rc=$?
	stage_pid=""
	sleep 1 # the stream prints what the stage wrote last
	kill "$stream_pid" 2>/dev/null || true
	wait "$stream_pid" 2>/dev/null || true
	stream_pid=""
}

echo "# from-zero build $(date -u +%FT%TZ): $(git rev-parse HEAD) ($(git rev-parse --abbrev-ref HEAD)), JOBS=${JOBS:-$(nproc)}, $(uname -m), stages: ${STAGES:-all}" | tee -a "$LOGDIR/driver.log"
failed=0
for s in "${stages[@]}"; do
	name="${s%%:*}" cmd="${s#*:}"
	if grep -q -P "^$name\t0\t" "$STATUS" 2>/dev/null; then
		echo "skip $name (done)" | tee -a "$LOGDIR/driver.log"
		continue
	fi
	printf '==> %s: %s\n' "$name" "$cmd" | tee -a "$LOGDIR/driver.log"
	run_stage "$name" "$cmd"
	secs=$((SECONDS - stage_start))
	printf '%s\t%s\t%s\n' "$name" "$stage_rc" "$secs" >>"$STATUS"
	if [ "$stage_rc" -eq 0 ]; then
		{
			echo "ok $name (${secs}s)"
			while read -r f; do printf '    %s: %s lines\n' "${f##*/}" "$(wc -l <"$f")"; done < <(stage_logs)
		} | tee -a "$LOGDIR/driver.log"
	else
		{
			echo "FAILED $name (rc=$stage_rc, ${secs}s)"
			while read -r f; do
				echo "--- last 40 lines of ${f#"$UD/"} ---"
				tail -n 40 "$f"
			done < <(stage_logs)
			echo "--- last 20 lines of the stage output ---"
			tail -n 20 "$LOGDIR/$name.log"
		} | tee -a "$LOGDIR/driver.log" >&2
		echo "::error::stage $name failed (rc=$stage_rc, ${secs}s); see this step's log and $LOGDIR/$name.log"
		failed=1
		break
	fi
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
