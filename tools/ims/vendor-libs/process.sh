#!/bin/bash
# Run a Ghidra script on a program that is already in the study's Ghidra project,
# without importing or analysing it again.
#
#   process.sh PROGRAM-NAME SCRIPT [ARG ...]
#
# PROGRAM-NAME is the name the library was imported under (lib-imscommon.so). The
# script is looked up next to this file. Ghidra's log goes to
# ghidra/out/<script>.log under the study directory. lib.sh tells where the study
# and Ghidra are.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"

[ $# -ge 2 ] || { echo "usage: process.sh PROGRAM-NAME SCRIPT [ARG ...]" >&2; exit 2; }
program="$1"
script="$2"
shift 2
[ -f "$here/$script" ] || { echo "no script $script next to process.sh" >&2; exit 2; }
study_needed || exit 2
mkdir -p "$study/ghidra/out"
log="$study/ghidra/out/$(basename "$script" .java).log"

run_headless "$log" -process "$program" -noanalysis -scriptPath "$here" -postScript "$script" "$@"
code=$?
echo "exit $code: $(grep -c '' "$log") log lines in $log"
grep -n "ERROR" "$log" | head -5 | cut -c1-240
exit "$code"
