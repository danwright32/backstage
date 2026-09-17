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
harness_begin "test runner tests" 10

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

harness_end
