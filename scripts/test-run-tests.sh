#!/bin/bash
# The runner must run every suite it finds, judge each by its EXIT CODE, refuse
# when it found none, and refuse when a suite it found did not run.
#
# backstage#1.
#
# THE DESIGN THIS DELIBERATELY DOES NOT COPY. The port source keeps a COMMITTED
# floor file holding the number of shell suites, so that a suite which silently
# stops being discovered is caught. It works, and it has a live complaint against
# it (ovation#351): every pair of branches that adds a suite conflicts on that one
# line, so two clean changes collide over content nobody wrote (L554). Cloning a
# proven pattern copies it as first written (L501), so this derives the expected
# count from the filesystem at run time and asserts that every suite DISCOVERED
# was also EXECUTED. That catches a suite that failed to start, which is the case
# the floor was really protecting, without a committed counter.
#
# WHAT THAT TRADE COSTS, stated rather than discovered later: a suite FILE being
# deleted is invisible to this, where the floor would have caught it. The remedy
# is review of a deletion, not a number, and it is written here so the next person
# weighing the floor again can see the choice was made rather than missed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. "$(dirname "$0")/lib/test-harness.sh"
harness_begin "test runner tests" 23

TARGET="scripts/run-tests.sh"
require_target "$TARGET"
harness_temp_dir WORK

OUT=""; CODE=0
# The runner is run against a throwaway tree, never this repository's own suites,
# so that this suite cannot be made to pass by the state of its neighbours.
run_runner() { OUT="$(BACKSTAGE_TEST_ROOT="$1" "$TARGET" 2>&1)"; CODE=$?; }
says() { if printf '%s' "$1" | grep -qF "$2"; then echo yes; else echo no; fi; }

make_tree() {
    [ -n "$WORK" ] || exit 1
    local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d/scripts"; printf '%s\n' "$d"
}
suite() { printf '#!/bin/bash\nexit %s\n' "$2" > "$1"; chmod +x "$1"; }

D="$(make_tree green)"
suite "$D/scripts/test-one.sh" 0
suite "$D/scripts/test-two.sh" 0
run_runner "$D"
check "a tree whose suites all pass is accepted" "$CODE" "0"
check "the runner says how many suites it ran" "$(says "$OUT" "2")" "yes"

D="$(make_tree red)"
suite "$D/scripts/test-one.sh" 0
suite "$D/scripts/test-two.sh" 1
run_runner "$D"
check "one red suite fails the run" "$( [ "$CODE" -ne 0 ] && echo failed || echo passed )" "failed"
check "the failing suite is named" "$(says "$OUT" "test-two.sh")" "yes"
check "the passing suite is not blamed" "$(says "$OUT" "test-one.sh FAILED")" "no"

# JUDGED BY EXIT CODE, never by a line of output: a tool's last line is routinely
# a different measurement than its verdict, and the more reassuring one (L184).
D="$(make_tree liar)"
printf '#!/bin/bash\necho "all tests passed"\nexit 1\n' > "$D/scripts/test-liar.sh"
chmod +x "$D/scripts/test-liar.sh"
run_runner "$D"
check "a suite printing success but exiting non zero still fails" "$( [ "$CODE" -ne 0 ] && echo failed || echo passed )" "failed"

# NOTHING TO RUN IS NOT A PASS (L98).
D="$(make_tree none)"
run_runner "$D"
check "a tree with no suites is refused" "$( [ "$CODE" -ne 0 ] && echo refused || echo allowed )" "refused"
check "an empty run says it found none" "$(says "$OUT" "no suites")" "yes"

# A run is judged first by the count it EXECUTED against the count it discovered,
# because a run that loses part of its work still prints a verdict (L288).
D="$(make_tree unrunnable)"
suite "$D/scripts/test-one.sh" 0
printf 'not executable\n' > "$D/scripts/test-two.sh"
chmod -x "$D/scripts/test-two.sh"
run_runner "$D"
check "a discovered suite that could not run is refused" "$( [ "$CODE" -ne 0 ] && echo refused || echo allowed )" "refused"
check "the suite that did not run is named" "$(says "$OUT" "test-two.sh")" "yes"

# --- the Swift package, which is macOS only ---
#
# The package imports AppKit and Network, neither of which exists on Linux, so
# `swift test` runs on macOS and is SKIPPED elsewhere. A skip that says nothing
# is the whole defect this suite exists to prevent: a run that quietly did less
# work still prints a verdict (L98, L288). So the skip has to SPEAK.
#
# Both the platform and the swift command are seams, because a suite that shells
# out to the real toolchain measures the toolchain (L2, L291).
swift_stub() { printf '#!/bin/bash\nexit %s\n' "$2" > "$1/swift"; chmod +x "$1/swift"; }

D="$(make_tree swift-pass)"
suite "$D/scripts/test-one.sh" 0
printf '// a package\n' > "$D/Package.swift"
swift_stub "$D" 0
OUT="$(BACKSTAGE_PLATFORM=Darwin BACKSTAGE_SWIFT="$D/swift" BACKSTAGE_TEST_ROOT="$D" "$TARGET" 2>&1)"; CODE=$?
check "a package whose swift tests pass is accepted" "$CODE" "0"
check "and the run says the swift tests ran" "$(says "$OUT" "swift")" "yes"

D="$(make_tree swift-fail)"
suite "$D/scripts/test-one.sh" 0
printf '// a package\n' > "$D/Package.swift"
swift_stub "$D" 1
OUT="$(BACKSTAGE_PLATFORM=Darwin BACKSTAGE_SWIFT="$D/swift" BACKSTAGE_TEST_ROOT="$D" "$TARGET" 2>&1)"; CODE=$?
check "failing swift tests fail the run" "$( [ "$CODE" -ne 0 ] && echo failed || echo passed )" "failed"
# NOT "the output must never say 0 failed": it legitimately does, because the
# SHELL suites did all pass, and that line is true. What matters is that the
# swift failure is named after it and the run ends non zero, so a reader cannot
# stop at the first summary and be wrong (L11).
check "and the swift failure is named, not just counted" "$(says "$OUT" "swift tests FAILED")" "yes"

# WHICH TEST FAILED, not merely that one did (backstage#55). The shell half names
# its failing suite by name; this half printed the word FAILED and nothing else,
# so a push refused by the gate said something in the package broke and gave no
# way to know what without running the whole thing again by hand.
swift_script() { printf '%s' "$2" > "$1/swift"; chmod +x "$1/swift"; }

D="$(make_tree swift-fail-named)"
suite "$D/scripts/test-one.sh" 0
printf '// a package\n' > "$D/Package.swift"
# The stub emits the REAL mark swift testing prints, built from its bytes with
# \x escapes rather than typed, because this repository's style gate refuses a
# literal one and bash 3.2 on macOS does not understand \u.
swift_script "$D" '#!/bin/bash
X=$(printf "\xe2\x9c\x98")
echo "$X Test theRefusalNamesBothNumbers() recorded an issue at MailSizeRefusalTests.swift:73:6: Expectation failed"
echo "$X Test theRefusalNamesBothNumbers() failed after 0.001 seconds with 1 issue."
echo "$X Test run with 167 tests in 21 suites failed after 1.1 seconds with 1 issue."
exit 1
'
OUT="$(BACKSTAGE_PLATFORM=Darwin BACKSTAGE_SWIFT="$D/swift" BACKSTAGE_TEST_ROOT="$D" "$TARGET" 2>&1)"; CODE=$?
check "the failing swift test is named, not just counted" "$(says "$OUT" "theRefusalNamesBothNumbers")" "yes"

# A BUILD THAT NEVER PRODUCED A TEST is the case with no test line to find, and the
# one where saying nothing is worst: there is no test to re-run to see the error.
D="$(make_tree swift-build-broken)"
suite "$D/scripts/test-one.sh" 0
printf '// a package\n' > "$D/Package.swift"
swift_script "$D" '#!/bin/bash
echo "Compiling BackstageGoogle"
echo "MailSender.swift:12:9: error: cannot find WidgetKind in scope"
echo "error: fatalError"
exit 1
'
OUT="$(BACKSTAGE_PLATFORM=Darwin BACKSTAGE_SWIFT="$D/swift" BACKSTAGE_TEST_ROOT="$D" "$TARGET" 2>&1)"; CODE=$?
check "a swift failure with no test lines still shows what went wrong" "$(says "$OUT" "cannot find WidgetKind in scope")" "yes"

# CAPPED, because a suite that breaks everywhere would otherwise bury the shell
# verdict above it under hundreds of lines, and the count says what was held back.
D="$(make_tree swift-fail-many)"
suite "$D/scripts/test-one.sh" 0
printf '// a package\n' > "$D/Package.swift"
swift_script "$D" '#!/bin/bash
X=$(printf "\xe2\x9c\x98")
for i in $(seq 1 100); do echo "$X Test case$i() recorded an issue at A.swift:1:1"; done
exit 1
'
OUT="$(BACKSTAGE_PLATFORM=Darwin BACKSTAGE_SWIFT="$D/swift" BACKSTAGE_TEST_ROOT="$D" "$TARGET" 2>&1)"; CODE=$?
check "a swift failure with many failures is capped and says how many were held back" "$(says "$OUT" "80 more")" "yes"

# AND A GREEN RUN STAYS QUIET, or the runner's own verdict is lost in the noise of
# a suite that had nothing wrong with it.
D="$(make_tree swift-pass-noisy)"
suite "$D/scripts/test-one.sh" 0
printf '// a package\n' > "$D/Package.swift"
swift_script "$D" '#!/bin/bash
echo "$(printf "\xe2\x9c\x94") Test run with 167 tests in 21 suites passed after 1.1 seconds."
exit 0
'
OUT="$(BACKSTAGE_PLATFORM=Darwin BACKSTAGE_SWIFT="$D/swift" BACKSTAGE_TEST_ROOT="$D" "$TARGET" 2>&1)"; CODE=$?
check "a green swift run does not dump its output" "$(says "$OUT" "167 tests")" "no"

# SKIPPED, AND SAID OUT LOUD. This is the case that would otherwise read exactly
# like a full run on the platform where half the work cannot happen.
D="$(make_tree swift-other-platform)"
suite "$D/scripts/test-one.sh" 0
printf '// a package\n' > "$D/Package.swift"
swift_stub "$D" 1
OUT="$(BACKSTAGE_PLATFORM=Linux BACKSTAGE_SWIFT="$D/swift" BACKSTAGE_TEST_ROOT="$D" "$TARGET" 2>&1)"; CODE=$?
check "a non macOS platform skips the swift tests rather than failing" "$CODE" "0"
check "and the skip says so out loud" "$(says "$OUT" "SKIPPED")" "yes"
check "and the skip names why it skipped" "$(says "$OUT" "macOS")" "yes"

# A tree with no package says nothing about swift at all, so the sentence above
# cannot become noise every repository prints.
D="$(make_tree no-package)"
suite "$D/scripts/test-one.sh" 0
OUT="$(BACKSTAGE_PLATFORM=Darwin BACKSTAGE_TEST_ROOT="$D" "$TARGET" 2>&1)"; CODE=$?
check "a tree with no package is accepted" "$CODE" "0"
check "and says nothing about swift" "$(says "$OUT" "swift")" "no"

harness_end
