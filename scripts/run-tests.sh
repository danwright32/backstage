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

# THE SWIFT PACKAGE, WHICH IS macOS ONLY.
#
# Sources/BackstageGoogle imports AppKit and Network, neither of which exists on
# Linux, so `swift test` can only run on macOS. The skip is SPOKEN rather than
# silent: a run that quietly did half the work still prints a verdict, and a
# reader has no way to tell it from a full one (L98, L288).
#
# Both seams exist so the runner's own suite can drive every branch without
# shelling out to the real toolchain, which would measure the toolchain rather
# than this decision (L2, L291).
# WHICH TEST FAILED, not merely that one did (backstage#55).
#
# Every shell suite is named when it fails. The swift half sent its output to
# /dev/null and printed the word FAILED, so a push refused by the gate said
# something among 167 tests broke and gave no way to know what without running the
# whole thing again by hand. Two outcomes that need different actions were told
# apart only by re-running (L11).
#
# MATCHED ON WORDS, NOT ON THE MARK swift testing prints. The mark differs between
# swift testing and XCTest and is a glyph this repository's style gate refuses to
# hold anyway, while "recorded an issue", "failed after" and "error:" are what both
# runners and the compiler actually write.
#
# AND A BUILD THAT NEVER PRODUCED A TEST is the case with NO test line to find, and
# the one where saying nothing is worst, because there is no test to re-run to see
# the error. So nothing matching is not nothing wrong: the tail is shown instead,
# and it says that is what it is (L98).
SWIFT_FAILURE_LINES=20
report_swift_failure() {
    local log="$1" matched total
    matched="$(grep -E 'recorded an issue|failed after|error:|^Test Case .*failed' "$log" 2>/dev/null)"
    if [ -z "$matched" ]; then
        echo "    no failing test or compiler error could be picked out of its output,"
        echo "    so here are its last $SWIFT_FAILURE_LINES lines:"
        tail -n "$SWIFT_FAILURE_LINES" "$log" | sed 's/^/    /'
        return
    fi
    total="$(printf '%s\n' "$matched" | wc -l | tr -d ' ')"
    printf '%s\n' "$matched" | head -n "$SWIFT_FAILURE_LINES" | sed 's/^/    /'
    # CAPPED, and the count says what was held back, or a suite that breaks
    # everywhere buries the shell verdict above it under hundreds of lines.
    if [ "$total" -gt "$SWIFT_FAILURE_LINES" ]; then
        echo "    (and $((total - SWIFT_FAILURE_LINES)) more, run swift test to see them all)"
    fi
}

SWIFT_FAILED=0
if [ -f "Package.swift" ]; then
    PLATFORM="${BACKSTAGE_PLATFORM:-$(uname -s)}"
    SWIFT="${BACKSTAGE_SWIFT:-swift}"
    if [ "$PLATFORM" != "Darwin" ]; then
        echo "swift tests SKIPPED: this package is macOS only (it imports AppKit and Network), and this is $PLATFORM."
        echo "    That is not the same as the swift tests passing."
    else
        # CAPTURED RATHER THAN DISCARDED, and only shown on a failure: a green run
        # that dumped a hundred lines of its own would bury this runner's verdict.
        SWIFT_LOG="$(mktemp)"
        if "$SWIFT" test > "$SWIFT_LOG" 2>&1; then
            echo "swift tests passed"
        else
            echo "swift tests FAILED"
            report_swift_failure "$SWIFT_LOG"
            SWIFT_FAILED=1
        fi
        rm -f "$SWIFT_LOG"
    fi
fi

[ "${#NOT_RUN[@]}" -gt 0 ] && exit 2
[ "${#FAILED[@]}" -gt 0 ] && exit 1
[ "$SWIFT_FAILED" -ne 0 ] && exit 1
exit 0
