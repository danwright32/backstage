#!/bin/bash
# Run every suite in this repository and report one verdict.
#
# backstage#1.
#
# JUDGED BY EXIT CODE, never by a line of output (L184).
#
# NOTHING TO RUN IS NOT A PASS. A runner that discovers no suites and reports
# success is indistinguishable from one that saw everything pass (L98).
#
# EVERY SUITE DISCOVERED MUST ALSO HAVE EXECUTED. A run that quietly loses part
# of its work still prints a verdict, and a check for zero failures catches none
# of it (L288). The expected count is derived here rather than committed to a
# floor file, for the reason set out in scripts/test-run-tests.sh.
#
# BACKSTAGE_TEST_ROOT exists so this runner's own suite can drive it against a
# throwaway tree. It is the ONLY seam, and it changes which tree is scanned,
# never what counts as a pass.
set -uo pipefail
ROOT="${BACKSTAGE_TEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || { echo "REFUSED: $ROOT cannot be entered."; exit 2; }

SELF="$(basename "$0")"
SUITES=()
while IFS= read -r suite; do
    [ "$(basename "$suite")" = "$SELF" ] && continue
    SUITES+=("$suite")
done < <(find scripts -maxdepth 1 -name 'test-*.sh' 2>/dev/null | sort)

if [ "${#SUITES[@]}" -eq 0 ]; then
    echo "REFUSED: found no suites under $ROOT/scripts, so nothing was checked."
    exit 2
fi

DISCOVERED="${#SUITES[@]}"
EXECUTED=0
FAILED=()
NOT_RUN=()

for suite in "${SUITES[@]}"; do
    if [ ! -x "$suite" ]; then
        # DISCOVERED BUT NOT RUNNABLE is its own outcome, never folded into a
        # pass: it is the shape L288 exists to catch.
        NOT_RUN+=("$suite")
        continue
    fi
    if "./$suite" > /dev/null 2>&1; then
        EXECUTED=$((EXECUTED + 1))
    else
        EXECUTED=$((EXECUTED + 1))
        FAILED+=("$suite")
    fi
done

# EXPANDED WITH A GUARD, because macOS ships bash 3.2, where "${arr[@]}" on an
# EMPTY array is an unbound variable error under `set -u`. Seen here: the green
# case exited 1 with "NOT_RUN[@]: unbound variable" and printed no verdict at
# all, so a perfectly healthy run reported as a failure.
if [ "${#NOT_RUN[@]}" -gt 0 ]; then
    for suite in "${NOT_RUN[@]}"; do
        echo "REFUSED: $suite was discovered but is not executable, so it did not run."
    done
fi
if [ "${#FAILED[@]}" -gt 0 ]; then
    for suite in "${FAILED[@]}"; do
        echo "$suite FAILED"
    done
fi

echo "ran $EXECUTED of $DISCOVERED suites, ${#FAILED[@]} failed"

[ "${#NOT_RUN[@]}" -gt 0 ] && exit 2
[ "${#FAILED[@]}" -gt 0 ] && exit 1
exit 0
