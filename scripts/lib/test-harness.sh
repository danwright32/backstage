#!/bin/bash
#
# PORTED FROM ANOTHER REPOSITORY. Do not edit this copy to fix a fault that is
# also in the origin: fix it there and re-port, or the two silently diverge and
# the shared definition stops being shared (L263).
#
# Ported-From: danwright32/ovation scripts/lib/test-harness.sh @ 1220f3caec84ff6ca4663638145eb2e10a46c0df
#
#   ported on: 2026-09-17 by backstage#1
#
# Every constant below was re-checked against what backstage needs rather than
# inherited: cloning a proven pattern copies it as first written, corrections
# included (L501). Nothing in this file was Ovation specific; the references to
# ovation issue numbers in the comments are the provenance of each rule and are
# left exactly as written, because rewriting them would destroy the only pointer
# to the failure each one came from.
# The one implementation of Ovation's shell test plumbing.
#
# ovation#19. Three suites carried identical hand copied copies of this after a
# single day of Phase 0, and a dozen more are coming. Sharing the code that
# APPLIES a rule is the part that matters: sharing only the data while copying
# the logic beside it is not consolidation, because the shared constant reads as
# the single source of truth and nobody asks whether the logic was duplicated
# (L370).
#
# Usage:
#
#     . "$(dirname "$0")/lib/test-harness.sh"
#     harness_begin "what this suite is about" <how many assertions it runs>
#     require_target "path/to/the/thing/under/test"
#     harness_temp_dir WORK                  # created, guarded and cleaned up for you
#     harness_on_exit 'some other cleanup'   # never `trap ... EXIT` yourself
#     harness_cannot_measure "why" "remedy"   # exits 2: proved nothing either way
#     check "description" "$actual" "$expected"
#     harness_end
#
# Three refusals live here so that no suite can forget them.
#
# NOTHING TO TEST IS NOT A PASS. `require_target` refuses when the thing under
# test is absent, rather than running zero assertions and reporting success
# (L98). Every suite written so far opened with a hand copied variant of this,
# which is exactly the kind of thing the twelfth suite omits.
#
# A SHORT RUN IS NOT A PASS. Every suite DECLARES how many assertions it runs,
# and a run that executed a different number is refused before its verdict is
# printed. A run is judged first by the count it executed against the count
# expected, and only then by its failures, because a run that loses part of its
# work still prints a verdict and a check for zero failures catches none of it
# (L288). No suite had this.
#
# A SUITE THAT DIED IS NOT A PASS. An exit before `harness_end` is caught by an
# EXIT trap and refused, because a suite that crashes after its last passing
# assertion otherwise leaves output that reads exactly like success.
_HARNESS_NAME=""
_HARNESS_EXPECTED=0
_HARNESS_RAN=0
_HARNESS_ENDED=0
PASS=0
FAIL=0

# Cleanup a suite registers is run BY the guard, never by a second EXIT trap.
# Bash keeps exactly ONE EXIT trap, so a suite writing its own would silently
# replace the guard and go back to reading as a pass when it died. Every line of
# such a suite still looks correct, which is what makes it worth taking out of
# the suite's hands entirely.
_HARNESS_CLEANUPS=()

harness_on_exit() {
    _HARNESS_CLEANUPS+=("$1")
}

_harness_run_cleanups() {
    local c
    for c in ${_HARNESS_CLEANUPS+"${_HARNESS_CLEANUPS[@]}"}; do
        eval "$c" || true
    done
    _HARNESS_CLEANUPS=()
}

_harness_exit_guard() {
    local status=$?
    _harness_run_cleanups
    [ "$_HARNESS_ENDED" = "1" ] && return "$status"
    echo "REFUSED: the suite '$_HARNESS_NAME' never reported."
    echo "         It exited before harness_end, after $_HARNESS_RAN of its $_HARNESS_EXPECTED assertions."
    echo "         Output above this line may look like a pass. It is not one."
    exit 1
}

harness_begin() {
    _HARNESS_CLEANUPS=()
    _HARNESS_NAME="$1"
    _HARNESS_EXPECTED="$2"
    _HARNESS_RAN=0
    _HARNESS_ENDED=0
    PASS=0
    FAIL=0

    # NO SUITE MAY INHERIT A GIT ENVIRONMENT, and this is part of the isolation
    # floor rather than a tidiness measure (L2).
    #
    # Six suites build a throwaway git repository, and git's own variables
    # OVERRIDE the directory a command is run in. With GIT_DIR set, a fixture's
    # `git init` re-initialises whatever GIT_DIR names and its `git commit`
    # commits into it, however carefully the fixture cd'd somewhere else first.
    #
    # Git EXPORTS those variables to its hooks, and the whole suite runs from the
    # pre-push hook. Measured on 2026-09-08, against the real repository: a
    # fixture's `git init -q -b main` set `core.bare = true` on Ovation's SHARED
    # config and wrote `user.email = t@t` into it, so every later commit in any
    # checkout or worktree would have been authored by `t`, and its
    # `git commit -qm one` landed a commit adding `f.txt` on the branch being
    # pushed. Both were found by hand afterwards, because nothing reported them.
    #
    # It is cleared HERE, once, rather than in each suite, because the variables
    # arrive from OUTSIDE every suite and a rule each fixture has to remember is
    # a rule that reaches nothing in exactly the run where it matters (L621). A
    # suite that deliberately tests behaviour under one of these sets it on the
    # single command it is testing, which still works.
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
          GIT_COMMON_DIR GIT_NAMESPACE

    trap _harness_exit_guard EXIT
}

# Scratch space, created and cleaned up BY THE HARNESS.
#
# Every suite needing one was writing the same three lines by hand: mktemp, a
# guard against it having failed, and a cleanup. The guard is the one that gets
# dropped, and `set -u` does not catch it, because an empty variable is set, not
# unset. A suite that skipped it would run `rm -rf` on a path built from nothing,
# at the filesystem root, and "that path happens not to exist" is precisely the
# reasoning L5 exists to stop. So it is not the suite's job.
#
# It SETS A NAMED VARIABLE rather than printing the path, and that is not a style
# choice. A `$(...)` substitution runs in a SUBSHELL, so a cleanup registered
# inside one is registered in a shell that exits immediately and never reaches
# the suite. The first version printed, and the directories were left behind on
# disk while every other assertion passed.
#
#     harness_temp_dir WORK    # then use "$WORK"
harness_temp_dir() {
    local _var="$1" _d
    _d="$(mktemp -d)"
    if [ -z "${_d:-}" ] || [ ! -d "$_d" ]; then
        _HARNESS_ENDED=1
        echo "REFUSED: could not create a temp directory, so nothing was checked." >&2
        exit 1
    fi
    harness_on_exit "rm -rf '$_d'"
    printf -v "$_var" '%s' "$_d"
}

# The thing under test must exist. Absent is a refusal naming what was missing,
# never a run of zero assertions.
require_target() {
    if [ ! -e "$1" ]; then
        _HARNESS_ENDED=1
        echo "REFUSED: $1 is missing, so nothing was checked."
        exit 1
    fi
}

# CANNOT MEASURE is a THIRD outcome, not a failure and not a pass.
#
# A suite that cannot reach the thing it judges (no toolchain, no built product,
# a sibling repository absent) has proved nothing either way, and that is a
# different fact from an assertion failing. It keeps its own exit code, 2, so a
# caller can tell the two apart without parsing text, and the crash guard leaves
# it alone rather than replacing it with the wrong cause (L11, L260, L98).
#
# It takes a reason and, optionally, the remedy, because a refusal whose message
# does not say what to do leaves the reader facing the same command and no way
# to learn why it did nothing (L148).
harness_cannot_measure() {
    _HARNESS_ENDED=1
    echo "CANNOT MEASURE: $_HARNESS_NAME"
    echo "    $1"
    [ "${2:-}" = "" ] || echo "    $2"
    echo "    Nothing was verified. This is not a pass."
    exit 2
}

check() {
    _HARNESS_RAN=$((_HARNESS_RAN+1))
    if [ "$2" = "$3" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        echo "FAIL: $1"
        echo "      expected '$3', got '$2'"
    fi
}

# A CONDITION WAIT IS AN ASSERTION, AND ONE THAT RUNS OUT FAILS BY NAME
# (ovation#303).
#
#     harness_wait_for "what is waited for" <polls> <interval> <command> [args...]
#
# Suites waited on a condition with a hand written loop that broke out after a
# fixed number of polls and then carried on as if the condition held. A wait
# that ran out said nothing, and the case after it failed on an assertion about a
# scenario that had never been staged, so the failure named the wrong thing and
# was read as a fault in the code under test (L98, L11).
#
# The command is run until it succeeds. Met or not, the wait counts as ONE
# assertion, so a suite's declared count does not change with the outcome, and a
# wait that runs out also returns 1 for a case that should skip what depends on
# it. A condition that needs a pipe belongs in a small function: under pipefail a
# `grep -q` ending early fails the command that fed it (L183).
harness_wait_for() {
    local what="$1" polls="$2" interval="$3" looked=0
    shift 3
    until "$@"; do
        looked=$((looked+1))
        if [ "$looked" -ge "$polls" ]; then
            check "waited for ${what}" "not met after ${polls} polls of ${interval}s" "met"
            return 1
        fi
        sleep "$interval"
    done
    check "waited for ${what}" "met" "met"
    return 0
}

harness_end() {
    _HARNESS_ENDED=1
    if [ "$_HARNESS_RAN" -ne "$_HARNESS_EXPECTED" ]; then
        echo "REFUSED: $_HARNESS_NAME executed $_HARNESS_RAN of the $_HARNESS_EXPECTED assertions it declares."
        if [ "$_HARNESS_RAN" -lt "$_HARNESS_EXPECTED" ]; then
            echo "         Part of this run did not happen. Its verdict is withheld."
            # NO NUMBER TO PASTE IN THIS DIRECTION, deliberately (ovation#346).
            # Writing what a short run executed is exactly how this check stops
            # noticing dropped assertions, which is the defect it exists to
            # prevent, so the remedy belongs to the other direction only.
            echo "         Find what did not run. Do NOT lower the declaration to match."
        else
            # THE LINE TO WRITE, NOT A DESCRIPTION OF IT (ovation#346). The
            # declared count is an aggregate over the whole file committed beside
            # it, so any two branches that add cases to one suite conflict on this
            # line and NEITHER side's number is right (L554). On 2026-09-15 two
            # branches took one suite to 93 and to 92, and the answer was 95.
            # Arithmetic over two diffs is how a wrong number gets committed, and
            # a wrong number set too low silently stops this check working.
            echo "         Assertions were added without the declaration being updated."
            echo "         Write the number THIS RUN executed, never one worked out from"
            echo "         two diffs, which is how a wrong one gets committed:"
            echo ""
            echo "         harness_begin \"$_HARNESS_NAME\" $_HARNESS_RAN"
            echo ""
        fi
        exit 1
    fi
    echo "$_HARNESS_NAME: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
}
