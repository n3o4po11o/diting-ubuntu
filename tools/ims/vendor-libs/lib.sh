#!/bin/bash
# Shared by headless.sh and process.sh: where the study and Ghidra are, and a run of
# Ghidra's headless analyzer that does not wait forever on its demangler.
#
# The Android vendor libraries and the Ghidra project are not in this repository:
# IMS_STUDY_DIR, or the working directory, is the directory of the study, with
# ghidra/project/ImsProject in it. GHIDRA_HOME is the Ghidra installation, and
# it has no default on purpose: a Ghidra newer than the one that made the
# project upgrades the project when it opens it, and the older one cannot open
# it afterwards.

study="${IMS_STUDY_DIR:-$PWD}"
ghidra="${GHIDRA_HOME:-}"

study_needed() {
	[ -d "$study/ghidra/project/ImsProject.rep" ] || {
		echo "no Ghidra project ImsProject under $study/ghidra/project: run from the study directory or set IMS_STUDY_DIR" >&2
		return 2
	}
	[ -n "$ghidra" ] || {
		echo "set GHIDRA_HOME to the Ghidra installation that made the project (a newer one upgrades it)" >&2
		return 2
	}
	[ -x "$ghidra/support/analyzeHeadless" ] || {
		echo "no Ghidra at $ghidra" >&2
		return 2
	}
}

# run_headless LOG ARG...: analyzeHeadless on the study's project, its output in LOG.
#
# Ghidra's GNU demangler sometimes starts and never answers; the run then waits
# forever with no CPU. The child is stopped when the log makes no progress, and
# Ghidra carries on without it.
run_headless() {
	local log="$1"
	shift
	"$ghidra/support/analyzeHeadless" "$study/ghidra/project" ImsProject "$@" > "$log" 2>&1 &
	local runner=$! quiet=0 java child demangler size
	while kill -0 "$runner" 2>/dev/null; do
		sleep 5
		# the launcher is the Java process itself or has it as its child
		java=""
		for child in "$runner" $(pgrep -P "$runner"); do
			case "$(ps -o command= -p "$child" 2>/dev/null)" in *nalyzeHeadless*) java="$child" ;; esac
		done
		[ -n "$java" ] || { quiet=0; continue; }
		demangler=$(pgrep -P "$java" -f demangler_gnu | head -1)
		[ -n "$demangler" ] || { quiet=0; continue; }
		size=$(wc -c < "$log" | tr -d ' ')
		sleep 20
		if kill -0 "$runner" 2>/dev/null && [ "$(wc -c < "$log" | tr -d ' ')" = "$size" ] &&
			pgrep -P "$java" -f demangler_gnu > /dev/null; then
			quiet=$((quiet + 1))
			if [ "$quiet" -ge 2 ]; then
				echo "demangler child $demangler silent: stopping it" >&2
				kill "$demangler" 2>/dev/null
				quiet=0
			fi
		else
			quiet=0
		fi
	done
	wait "$runner"
}
