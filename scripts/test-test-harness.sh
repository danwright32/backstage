#!/bin/bash
#
# PORTED FROM ANOTHER REPOSITORY. Do not edit this copy to fix a fault that is
# also in the origin: fix it there and re-port, or the two silently diverge and
# the shared definition stops being shared (L263).
#
# Ported-From: danwright32/ovation scripts/test-test-harness.sh @ 1220f3caec84ff6ca4663638145eb2e10a46c0df
#
#   ported on: 2026-09-17 by backstage#1
#
# Every constant below was re-checked against what backstage needs rather than
# inherited: cloning a proven pattern copies it as first written, corrections
# included (L501). Nothing in this file was Ovation specific; the references to
# ovation issue numbers in the comments are the provenance of each rule and are
# left exactly as written, because rewriting them would destroy the only pointer
# to the failure each one came from.
# The shared test harness must count, must refuse when its target is absent, and
# must refuse a run that executed FEWER assertions than it declared.
#
# ovation#19. Three suites carried identical hand copied plumbing after one day,
# and Phase 0 will produce roughly a dozen. One implementation, so the refusals
# below cannot be forgotten in the twelfth suite (L370: sharing the data while
# copying the code that applies it is not consolidation).
#
# The assertion count is the part no suite had. A run is judged FIRST by the
# count it executed against the count expected, and only then by its failures,
# because a run that loses part of its work still prints a verdict and a check
# for zero failures catches none of it (L288).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else
        FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "      expected '$3', got '$2'"; fi
}

HARNESS="scripts/lib/test-harness.sh"
if [ ! -f "$HARNESS" ]; then
    echo "FAIL: $HARNESS is missing, so nothing was checked"
    exit 1
fi

WORK="$(mktemp -d)"
if [ -z "${WORK:-}" ] || [ ! -d "$WORK" ]; then
    echo "FAIL: could not create a temp directory, so nothing was checked"
    exit 1
fi
trap 'rm -rf "$WORK"' EXIT INT TERM

# Fixture suites are written to disk and run as SUBPROCESSES, because the
# harness's whole job is to decide an exit status, and a sourced copy would
# take this file down with it.
suite() { cat > "$WORK/$1.sh"; chmod +x "$WORK/$1.sh"; }
run()   { ( cd "$PWD" && "$WORK/$1.sh" 2>&1 ); }

# 1. A suite whose assertions all pass, and whose count matches what it declared.
suite allgood <<SUITE
#!/bin/bash
cd "$PWD" || exit 1
. "$PWD/$HARNESS"
harness_begin "all good" 2
check "one" "a" "a"
check "two" "b" "b"
harness_end
SUITE
OUT1="$(run allgood)"; ST1=$?
check "a fully passing suite exits 0" "$ST1" "0"
check "and says how many passed" "$(printf '%s' "$OUT1" | grep -c "2 passed, 0 failed")" "1"

# 2. A failing assertion must fail the run and name the difference.
suite onebad <<SUITE
#!/bin/bash
cd "$PWD" || exit 1
. "$PWD/$HARNESS"
harness_begin "one bad" 2
check "one" "a" "a"
check "the bad one" "actual-value" "expected-value"
harness_end
SUITE
OUT2="$(run onebad)"; ST2=$?
check "a suite with a failing assertion exits non zero" \
    "$([ "$ST2" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "and names the assertion that failed" \
    "$(printf '%s' "$OUT2" | grep -c "the bad one")" "1"
check "and shows both values, not merely that it failed" \
    "$(printf '%s' "$OUT2" | grep -c "expected 'expected-value', got 'actual-value'")" "1"

# 3. THE ONE NO SUITE HAD. A run that executed fewer assertions than it declared
#    must be REFUSED, even though every assertion it did run passed. This is the
#    shape where a suite silently loses half its work and still reports success.
suite short <<SUITE
#!/bin/bash
cd "$PWD" || exit 1
. "$PWD/$HARNESS"
harness_begin "short run" 5
check "one" "a" "a"
check "two" "b" "b"
harness_end
SUITE
OUT3="$(run short)"; ST3=$?
check "a run that executed fewer assertions than declared is refused" \
    "$([ "$ST3" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "and it names BOTH numbers, so the gap is readable" \
    "$(printf '%s' "$OUT3" | grep -c "2 of the 5")" "1"
check "and it does not report the run as passing" \
    "$(printf '%s' "$OUT3" | grep -c "0 failed$")" "0"

# 4. A run that executed MORE than declared is also refused. The count is a
#    contract in both directions: a suite that grew without its declaration
#    being updated is a suite nobody re-read.
suite over <<SUITE
#!/bin/bash
cd "$PWD" || exit 1
. "$PWD/$HARNESS"
harness_begin "over run" 1
check "one" "a" "a"
check "two" "b" "b"
harness_end
SUITE
OUT4="$(run over)"; ST4=$?
check "a run that executed MORE assertions than declared is refused too" \
    "$([ "$ST4" -ne 0 ] && echo nonzero || echo zero)" "nonzero"

# 4b. AND THE REFUSAL IS THE LINE TO WRITE (ovation#346). The declared count is an
#     aggregate over the whole file committed beside it, so any two branches that
#     add cases to one suite conflict on that line, and NEITHER side's number is
#     right (L554). On 2026-09-15 ovation#124 took one suite to 93 and ovation#339
#     took the same suite to 92; the true figure was 95 and could only be had by
#     running it. The safe resolution is to run the suite and copy what it
#     reports, and nothing taught that, so the message is the line itself rather
#     than a description of one (L399, L406).
check "and the refusal is the declaration to write, ready to paste" \
    "$(printf '%s' "$OUT4" | grep -c 'harness_begin "over run" 2')" "1"
check "and it says the number came from this run, not from adding up two diffs" \
    "$(printf '%s' "$OUT4" | grep -c 'two diffs')" "1"

# 4c. AND A SHORT RUN IS NEVER HANDED A NUMBER TO PASTE. Writing what a short run
#     executed is exactly how the check stops noticing dropped assertions, which
#     is the defect it exists to prevent, so the remedy belongs to one direction
#     only (L11, L93).
check "a short run is given no number to paste, because that would silence the check" \
    "$(printf '%s' "$OUT3" | grep -c 'harness_begin "short run"')" "0"

# 5. The target refusal. Every suite so far opens with a variant of "the thing
#    under test is missing, so nothing was checked". A suite that finds nothing
#    to test must never exit 0 (L98), and one implementation means it cannot be
#    forgotten in the twelfth suite.
suite notarget <<SUITE
#!/bin/bash
cd "$PWD" || exit 1
. "$PWD/$HARNESS"
harness_begin "no target" 1
require_target "$WORK/does-not-exist"
check "never reached" "a" "a"
harness_end
SUITE
OUT5="$(run notarget)"; ST5=$?
check "a suite whose target is absent refuses" \
    "$([ "$ST5" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "and says nothing was checked rather than reporting a pass" \
    "$(printf '%s' "$OUT5" | grep -c "nothing was checked")" "1"
check "and names the target it could not find" \
    "$(printf '%s' "$OUT5" | grep -c "does-not-exist")" "1"

# 6. A suite that declares a count and then DIES before harness_end must not be
#    read as success by anything that only looks for the word FAIL. This is the
#    crash case, and it is why the count exists at all.
suite dies <<SUITE
#!/bin/bash
cd "$PWD" || exit 1
. "$PWD/$HARNESS"
harness_begin "dies early" 3
check "one" "a" "a"
exit 0
SUITE
OUT6="$(run dies)"; ST6=$?
check "a suite that exits 0 before harness_end is still refused" \
    "$([ "$ST6" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "and it says the suite never reported" \
    "$(printf '%s' "$OUT6" | grep -c "never reported")" "1"

# 7. A SUITE THAT NEEDS ITS OWN CLEANUP MUST NOT LOSE THE CRASH GUARD.
#    Found while migrating the existing suites: two of them set their own
#    `trap ... EXIT` to remove a temp directory, which SILENTLY REPLACES the
#    harness's guard. Bash keeps one EXIT trap, so the last one registered wins,
#    and the suite would go back to reading as a pass when it died. The suite
#    still looks correct at every line, which is what makes it dangerous.
#
#    So cleanup is registered THROUGH the harness, and the guard runs it.
suite cleanup_and_die <<SUITE
#!/bin/bash
cd "$PWD" || exit 1
. "$PWD/$HARNESS"
harness_begin "cleanup and die" 3
touch "$WORK/sentinel-was-not-removed"
harness_on_exit 'rm -f "$WORK/sentinel-was-not-removed"'
check "one" "a" "a"
exit 0
SUITE
OUT7="$(run cleanup_and_die)"; ST7=$?
check "a suite that registers cleanup and dies is still refused" \
    "$([ "$ST7" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "and it still says the suite never reported" \
    "$(printf '%s' "$OUT7" | grep -c "never reported")" "1"
check "and the registered cleanup DID run" \
    "$([ -e "$WORK/sentinel-was-not-removed" ] && echo left-behind || echo removed)" "removed"

# 8. The same cleanup must also run on a NORMAL, passing end. Cleanup placed
#    only where things go wrong is reached only by the paths that fail (L515).
suite cleanup_and_pass <<SUITE
#!/bin/bash
cd "$PWD" || exit 1
. "$PWD/$HARNESS"
harness_begin "cleanup and pass" 1
touch "$WORK/sentinel-pass"
harness_on_exit 'rm -f "$WORK/sentinel-pass"'
check "one" "a" "a"
harness_end
SUITE
OUT8="$(run cleanup_and_pass)"; ST8=$?
check "a passing suite with cleanup still exits 0" "$ST8" "0"
check "and its cleanup ran on the success path too" \
    "$([ -e "$WORK/sentinel-pass" ] && echo left-behind || echo removed)" "removed"

# 9. CANNOT MEASURE MUST SURVIVE THE GUARD.
#    Also found while migrating. Two suites already refuse with exit 2 when the
#    thing they need is absent (no xcodegen, no built product), which is a
#    DIFFERENT outcome from a failed assertion and carries its own exit code so
#    a caller can tell them apart. Installing the crash guard silently turned
#    both into exit 1 with the words "never reported", which is the wrong cause
#    and the wrong code: two outcomes that had distinct messages and distinct
#    consequences collapsed into one (L11, L260).
suite cannot_measure <<SUITE
#!/bin/bash
cd "$PWD" || exit 1
. "$PWD/$HARNESS"
harness_begin "cannot measure" 3
harness_cannot_measure "xcodegen is not installed" "install it with: brew install xcodegen"
check "never reached" "a" "a"
harness_end
SUITE
OUT9="$(run cannot_measure)"; ST9=$?
check "cannot measure keeps its own exit code, distinct from a failure" "$ST9" "2"
check "and it says CANNOT MEASURE" \
    "$(printf '%s' "$OUT9" | grep -c "CANNOT MEASURE")" "1"
check "and it gives the reason it could not measure" \
    "$(printf '%s' "$OUT9" | grep -c "xcodegen is not installed")" "1"
check "and it carries the remedy, so the message is actionable" \
    "$(printf '%s' "$OUT9" | grep -c "brew install xcodegen")" "1"
check "and the crash guard does NOT overwrite it with never reported" \
    "$(printf '%s' "$OUT9" | grep -c "never reported")" "0"
check "and it never claims a pass" \
    "$(printf '%s' "$OUT9" | grep -c "passed, 0 failed")" "0"

# 10. THE TEMP DIRECTORY IS THE HARNESS'S JOB TOO.
#     Every suite that needs scratch space was writing the same three lines by
#     hand: mktemp, a guard against it having failed, and a cleanup. The guard is
#     the one that gets dropped, and `set -u` does NOT catch it, because an empty
#     variable is set. A suite that skipped it would run `rm -rf "/whatever"` at
#     the filesystem root, and "that path happens not to exist" is the reasoning
#     L5 exists to stop. Same answer as the exit trap: take it out of the suite's
#     hands.
suite tempdir <<SUITE
#!/bin/bash
cd "$PWD" || exit 1
. "$PWD/$HARNESS"
harness_begin "temp dir" 1
harness_temp_dir d
echo "\$d" > "$WORK/reported-dir"
touch "\$d/a-file"
check "the directory exists and is writable" "\$([ -f "\$d/a-file" ] && echo yes)" "yes"
harness_end
SUITE
OUT10="$(run tempdir)"; ST10=$?
check "a suite can get a temp directory from the harness" "$ST10" "0"
DIR10="$(cat "$WORK/reported-dir" 2>/dev/null)"
check "and it was a real directory, not an empty string" \
    "$([ -n "$DIR10" ] && echo named || echo empty)" "named"
check "and the harness removed it when the suite ended" \
    "$([ -e "$DIR10" ] && echo left-behind || echo removed)" "removed"

# 11. And it is removed on the CRASH path too, not only the tidy one (L515).
suite tempdir_dies <<SUITE
#!/bin/bash
cd "$PWD" || exit 1
. "$PWD/$HARNESS"
harness_begin "temp dir dies" 3
harness_temp_dir d
echo "\$d" > "$WORK/reported-dir-2"
touch "\$d/a-file"
exit 0
SUITE
OUT11="$(run tempdir_dies)"; ST11=$?
DIR11="$(cat "$WORK/reported-dir-2" 2>/dev/null)"
check "a suite that dies is still refused when it used a temp dir" \
    "$([ "$ST11" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "and the temp directory was still removed" \
    "$([ -e "$DIR11" ] && echo left-behind || echo removed)" "removed"

# ---------------------------------------------------------------------------
# 12. NO SUITE MAY INHERIT A GIT ENVIRONMENT. Six suites build a throwaway git
# repository with `git init` and `git commit`, and git's variables OVERRIDE the
# directory a command is run in: with GIT_DIR set, a fixture's `git init` re-
# initialises whatever GIT_DIR names and its `git commit` commits into it.
#
# Git EXPORTS those variables to its hooks, and the whole suite runs from the
# pre-push hook. Measured on 2026-09-08, on the real repository: a fixture's
# `git init -q -b main` set `core.bare = true` on Ovation's shared config and
# wrote `user.email = t@t` into it, so every later commit in any checkout or
# worktree would have been authored by `t`; and its `git commit -qm one` landed a
# commit titled "one" adding `f.txt` on the branch that was being pushed.
#
# That is a test writing into live state, which the isolation floor exists to
# make structurally impossible (L2), and no seam in any individual suite could
# have stopped it: the variables arrive from outside every one of them. So the
# harness every suite already sources clears them once, for all of them.
#
# The fixture below asks the running suite what it can see, rather than asserting
# about the harness's source, so a future harness that stops clearing them fails
# here rather than reading as correct.
suite git_env <<SUITE
#!/bin/bash
cd "$PWD" || exit 1
. "$PWD/$HARNESS"
harness_begin "git env" 1
printf '%s|%s|%s\n' "\${GIT_DIR:-unset}" "\${GIT_WORK_TREE:-unset}" "\${GIT_INDEX_FILE:-unset}" \
    > "$WORK/seen-git-env"
check "one" "a" "a"
harness_end
SUITE
GIT_DIR=/nowhere/decoy.git GIT_WORK_TREE=/nowhere GIT_INDEX_FILE=/nowhere/index \
    run git_env >/dev/null 2>&1
check "a suite cannot see a GIT_DIR the environment handed it" \
    "$(cat "$WORK/seen-git-env" 2>/dev/null)" "unset|unset|unset"

# ---------------------------------------------------------------------------
# 13. A CONDITION WAIT THAT RUNS OUT FAILS BY NAME (ovation#303).
#
# The runner suite waited on conditions with a hand written loop that broke out
# after a fixed number of polls and then carried on as if the condition held. A
# wait that ran out was silent, and the case after it failed on an assertion
# about a scenario that was never staged, so the failure named the wrong thing
# (L98, L11). Measured 2026-09-14: making case 236c's wait unmeetable reported
# "and how many different holders went ahead of it" and nothing about the wait.
#
# So the wait is a harness helper, and it is an assertion: met or not, it counts
# as one, so a suite's declared count does not move with the outcome (L288).
suite wait_unmet <<SUITE
#!/bin/bash
cd "$PWD" || exit 1
. "$PWD/$HARNESS"
harness_begin "unmet wait" 1
harness_wait_for "the sentinel to appear" 3 0.01 test -e "$WORK/never-created"
echo "\$?" > "$WORK/wait-unmet-status"
harness_end
SUITE
OUT13="$(run wait_unmet)"; ST13=$?
check "a suite whose condition wait runs out fails" \
    "$([ "$ST13" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "and it names the wait that was not met" \
    "$(printf '%s' "$OUT13" | grep -c "^FAIL: waited for the sentinel to appear$")" "1"
check "and says how long it waited, in polls and their interval" \
    "$(printf '%s' "$OUT13" | grep -c "got 'not met after 3 polls of 0.01s'")" "1"
check "and tells the suite, so a case can skip what depends on it" \
    "$(cat "$WORK/wait-unmet-status" 2>/dev/null)" "1"

# A wait that is met passes, counts as exactly one assertion, and keeps polling
# until it is met rather than judging the first look (L159).
suite wait_met <<SUITE
#!/bin/bash
cd "$PWD" || exit 1
. "$PWD/$HARNESS"
harness_begin "met wait" 1
third_look() {
    printf 'x' >> "$WORK/looks"
    [ "\$(wc -c < "$WORK/looks" | tr -d ' ')" -ge 3 ]
}
harness_wait_for "the third look" 10 0.01 third_look
harness_end
SUITE
rm -f "$WORK/looks"
OUT13B="$(run wait_met)"; ST13B=$?
check "a condition wait that is met passes as one assertion" "$ST13B" "0"
check "and it looked until the condition held, not once" \
    "$(wc -c < "$WORK/looks" 2>/dev/null | tr -d ' ')" "3"

echo "test harness tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
