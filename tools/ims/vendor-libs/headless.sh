#!/bin/bash
# Run Ghidra's headless analyzer on an Android vendor library and decompile the
# functions matching a regular expression, with their callees.
#
#   headless.sh LIBRARY OUT-DIRECTORY REGEX [MAX-FUNCTIONS] [CALLEE-DEPTH]
#
# OUT-DIRECTORY must not exist yet or be empty: it gets one C file per function and
# index.txt, and Ghidra's log goes to OUT-DIRECTORY.log. Every run imports the
# library again, which takes minutes. lib.sh tells where the study and Ghidra are.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lib.sh"

[ $# -ge 3 ] && [ $# -le 5 ] || { echo "usage: headless.sh LIBRARY OUT-DIRECTORY REGEX [MAX-FUNCTIONS] [CALLEE-DEPTH]" >&2; exit 2; }
library="$1"
out="$2"
regex="$3"
max="${4:-200}"
depth="${5:-0}"
[ -f "$library" ] || { echo "no library at $library" >&2; exit 2; }
study_needed || exit 2
if [ -e "$out" ] && [ -n "$(ls -A "$out")" ]; then
	echo "$out exists and is not empty: remove it first" >&2
	exit 2
fi
mkdir -p "$out"

run_headless "$out.log" -import "$library" -overwrite -scriptPath "$here" \
	-postScript DecompileMatching.java "$out" "$regex" "$max" "$depth"
code=$?
count=0
for file in "$out"/*.c; do
	[ -f "$file" ] && count=$((count + 1))
done
echo "headless exit $code: $(grep -c '' "$out.log" 2>/dev/null || :) log lines, $count C files in $out"
tail -3 "$out.log" | cut -c1-170
exit "$code"
