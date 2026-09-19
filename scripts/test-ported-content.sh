#!/bin/bash
# A ported file must still be what it was when it was ported (backstage#9).
#
# scripts/check-ported-artifacts.sh verifies that the commit a ported file NAMES
# is still on its origin's main. It never compares the CONTENT, so a copy edited
# here drifts in silence and that check stays green for ever, while every ported
# header says in as many words "do not edit this copy". A constraint recorded
# only as a comment is enforced by nothing, and sitting there makes it read as
# binding (L407).
#
# FOUR OUTCOMES, because the real population has four (L11, L147). Of the 23
# artifacts here, 8 are the origin's file with one comment block inserted and 15
# were deliberately ADAPTED at port time. A check offering only identical,
# authorised or drifted would refuse 15 correct files on its first run.
#
# THE SUITE FOLLOWS THE REMEDY THE MESSAGE PRINTS rather than computing a digest
# of its own. A remedy a failure message tells somebody to run is executed by
# nothing until the moment it is needed (L406), and a suite that worked the
# digest out for itself would be asserting against its own copy of the rule
# rather than against the one the message hands a reader (L370).
#
# NOTHING HERE READS A REAL SIBLING except the one case that says so, and that
# case stands down by name where the siblings are not on the machine, as a fresh
# clone and every CI runner are (L2, L411).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO_ROOT="$(pwd)"
. "$(dirname "$0")/lib/test-harness.sh"
harness_begin "ported content tests" 25

TARGET="scripts/check-ported-content.sh"
require_target "$TARGET"
require_target "scripts/check-ported-artifacts.sh"
harness_temp_dir WORK

MARKER="Ported""-From:"
ADAPTED="Ported""-Adapted:"
DIVERGENCE="Ported""-Divergence:"

says() { if printf '%s' "$1" | grep -qF "$2"; then echo yes; else echo no; fi; }
counts() { printf '%s' "$1" | grep -c "$2" || true; }

# THE ISSUE STATE COMES FROM A SEAM, so no case here reaches GitHub. Number 1 is
# open, 2 is closed, and anything else answers with something unreadable, which
# is its own outcome rather than either of the other two.
STATE_CMD="$WORK/issue-state.sh"
cat > "$STATE_CMD" <<'STATE'
#!/bin/bash
case "$2" in
  1) echo OPEN ;;
  2) echo CLOSED ;;
  *) echo "could not be read" ;;
esac
STATE
chmod +x "$STATE_CMD"

# A throwaway origin repository holding one file at one commit. Its remote url
# carries the slug, because the check resolves a sibling by asking each candidate
# what its origin IS rather than by matching a directory name (L15).
make_origin() {
    # DECLARED ON SEPARATE LINES. macOS ships bash 3.2, where a single `local`
    # does not make its earlier names available to its later right hand sides,
    # so `local name="$1" d="$WORK/origin-$name"` dies under `set -u` with
    # "name: unbound variable" and the fixture is never built (L486).
    [ -n "${WORK:-}" ] || exit 1
    local name="$1"
    local d="$WORK/origin-$name"
    rm -rf "$d"; mkdir -p "$d"
    printf '#!/bin/bash\n# The origin says this.\necho one\necho two\n' > "$d/ported.sh"
    ( cd "$d" && git init -q -b main >/dev/null 2>&1 \
        && git remote add origin "https://example.invalid/danwright32/$name.git" \
        && git add -- ported.sh \
        && git -c user.email=fixture@fixture.invalid -c user.name=fixture \
               commit -q -m "the origin" ) || return 1
    git -C "$d" rev-parse HEAD
}

make_tree() {
    [ -n "${WORK:-}" ] || exit 1
    local d="$WORK/tree-$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s\n' "$d"
}

# The origin's file with backstage's own header block inserted, which is what a
# port that was taken whole looks like.
in_step_copy() {
    local into="$1" slug="$2" commit="$3"
    {
        printf '#!/bin/bash\n'
        printf '# %s %s ported.sh @ %s\n' "$MARKER" "$slug" "$commit"
        printf '#\n# Ported by a fixture. Do not edit this copy.\n'
        printf '# The origin says this.\necho one\necho two\n'
    } > "$into"
}

OUT=""; CODE=0
run_check() {
    OUT="$(BACKSTAGE_PORT_SCAN_ROOT="$1" \
           BACKSTAGE_SIBLING_SEARCH_ROOTS="$WORK" \
           BACKSTAGE_ISSUE_STATE="$STATE_CMD" \
           "./$TARGET" 2>&1)"; CODE=$?
}

# The line the check tells a reader to write, taken from its own output.
printed_record() { printf '%s' "$1" | grep -F "$ADAPTED" | tail -1 | sed 's/^[[:space:]]*//'; }

# ---------------------------------------------------------------------------
# 1. TAKEN WHOLE. The origin's file plus one block of comments is in step, and
# needs nothing recorded: the origin and the commit pin it exactly.
COMMIT="$(make_origin whole)"
T="$(make_tree whole)"
in_step_copy "$T/ported.sh" "danwright32/whole" "$COMMIT"
run_check "$T"
check "a port taken whole is accepted" "$CODE" "0"
check "and it is reported as in step" "$(counts "$OUT" '^IN STEP:')" "1"

# ---------------------------------------------------------------------------
# 2. ONE CHARACTER CHANGED, AND NOTHING RECORDING IT. The case the issue asks
# for, and the one every ported header forbids in prose and nothing enforced.
COMMIT="$(make_origin edited)"
T="$(make_tree edited)"
in_step_copy "$T/ported.sh" "danwright32/edited" "$COMMIT"
sed -i.bak 's/echo two/echo three/' "$T/ported.sh" && rm -f "$T/ported.sh.bak"
run_check "$T"
check "a ported file edited here is refused" "$CODE" "1"
check "and it is named" "$(says "$OUT" "ported.sh")" "yes"
check "and the outcome says it drifted" "$(counts "$OUT" '^DRIFTED:')" "1"

# 3. AND THE REMEDY IT PRINTS ACTUALLY WORKS. A remedy nothing runs until the
# moment it is needed is a remedy nobody has tried (L406).
RECORD="$(printed_record "$OUT")"
check "the refusal prints a line to write, not a description of one" \
    "$(says "$RECORD" "$ADAPTED")" "yes"
python3 - "$T/ported.sh" "$RECORD" <<'INSERT'
import sys
path, record = sys.argv[1], sys.argv[2]
lines = path and open(path).read().split("\n")
for index, line in enumerate(lines):
    if "-From:" in line:
        lines.insert(index + 1, record)
        break
open(path, "w").write("\n".join(lines))
INSERT
run_check "$T"
check "writing that line exactly as printed makes the check pass" "$CODE" "0"
check "and the file is then reported as adapted" "$(counts "$OUT" '^ADAPTED:')" "1"

# ---------------------------------------------------------------------------
# 4. AN EDIT AFTER THE RECORD is the defect this whole check is named for, and
# it gets its own wording: this is not a port that differs, it is a port that
# has CHANGED since somebody looked at it (L11).
printf 'echo four\n' >> "$T/ported.sh"
run_check "$T"
check "an edit made after the record is refused" "$CODE" "1"
check "and it says the file was edited since it was ported" \
    "$(counts "$OUT" '^EDITED SINCE IT WAS PORTED:')" "1"

# ---------------------------------------------------------------------------
# 5. A DIVERGENCE AUTHORISED BY AN OPEN ISSUE. check-ci-workflow.sh really is in
# this state, pending ovation#399, and the only record of it was a paragraph.
COMMIT="$(make_origin authorised)"
T="$(make_tree authorised)"
in_step_copy "$T/ported.sh" "danwright32/authorised" "$COMMIT"
sed -i.bak 's/echo two/echo three/' "$T/ported.sh" && rm -f "$T/ported.sh.bak"
run_check "$T"
RECORD="$(printed_record "$OUT")"
add_line() {
    python3 - "$1" "$2" <<'INSERT'
import sys
path, line = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
for index, existing in enumerate(lines):
    if "-From:" in existing:
        lines.insert(index + 1, line)
        break
open(path, "w").write("\n".join(lines))
INSERT
}
add_line "$T/ported.sh" "$RECORD"
add_line "$T/ported.sh" "# $DIVERGENCE danwright32/ovation#1"
run_check "$T"
check "a divergence naming an OPEN issue is accepted" "$CODE" "0"
check "and it is reported as diverged rather than merely adapted" \
    "$(counts "$OUT" '^DIVERGED:')" "1"

# 6. AND A CLOSED ONE IS NOT. An authorisation that outlives its reason is not
# an authorisation: if the origin has landed the fix, the copy must be re-ported.
sed -i.bak "s|ovation#1|ovation#2|" "$T/ported.sh" && rm -f "$T/ported.sh.bak"
run_check "$T"
check "a divergence naming a CLOSED issue is refused" "$CODE" "1"
check "and it says the authorisation expired" \
    "$(counts "$OUT" '^AUTHORISATION EXPIRED:')" "1"

# 7. A STATE THAT COULD NOT BE READ IS NOT PERMISSION. A guard that falls silent
# exactly when its source fails is a guard that approves on failure (L345, L42).
sed -i.bak "s|ovation#2|ovation#9|" "$T/ported.sh" && rm -f "$T/ported.sh.bak"
run_check "$T"
check "an authorisation whose state cannot be read is not a pass" \
    "$( [ "$CODE" -ne 0 ] && echo withheld || echo passed )" "withheld"
check "and it says so rather than naming a verdict it never reached" \
    "$(counts "$OUT" '^CANNOT MEASURE:')" "1"

# ---------------------------------------------------------------------------
# 8. A RECORD ON A FILE THAT NEEDS NONE is a claim nothing maintains, and it
# would go on reading as a considered decision (L346).
COMMIT="$(make_origin spurious)"
T="$(make_tree spurious)"
in_step_copy "$T/ported.sh" "danwright32/spurious" "$COMMIT"
add_line "$T/ported.sh" "# $ADAPTED 0000000000000000000000000000000000000000000000000000000000000000"
run_check "$T"
check "a record on a file that is in step is refused" "$CODE" "1"

# ---------------------------------------------------------------------------
# 9. TWO KINDS OF CANNOT MEASURE, kept apart exactly as check-ported-artifacts.sh
# keeps them: a sibling that is not on this machine is a question nothing here
# could ever answer, and a sibling that IS here and cannot answer is a fault on
# this machine (L11, L260).
T="$(make_tree absent-sibling)"
in_step_copy "$T/ported.sh" "danwright32/nosuchrepoanywhere" "0123456789abcdef0123456789abcdef01234567"
run_check "$T"
check "a sibling that is not on this machine is its own outcome" "$CODE" "2"
check "and it is never reported as a pass" "$(counts "$OUT" '^CANNOT MEASURE:')" "1"

COMMIT="$(make_origin missing-commit)"
T="$(make_tree missing-commit)"
in_step_copy "$T/ported.sh" "danwright32/missing-commit" "0123456789abcdef0123456789abcdef01234567"
run_check "$T"
check "a sibling that is here and does not hold the commit is the other outcome" "$CODE" "4"

# ---------------------------------------------------------------------------
# 10. NOTHING FOUND IS NOT A PASS (L98). A tree with no ported file at all must
# never read as a tree whose ports were all verified.
T="$(make_tree empty)"
printf 'nothing ported here\n' > "$T/plain.txt"
run_check "$T"
check "a tree with no ported artifact is refused, not passed" "$CODE" "3"

# ---------------------------------------------------------------------------
# 11. THE REAL TREE, AND THE ONE THING TWO SEPARATE SCANNERS CAN GET WRONG.
#
# This check finds the ported artifacts itself rather than editing the ported
# check to do it, which would introduce the very divergence it reports. The cost
# is two pieces of code that each enumerate the artifacts, and it is paid down
# here: they are asserted to find the SAME SET, so a drift between the two is a
# red suite rather than a silent hole (L582, L370).
SIBLINGS_HERE=no
if ./scripts/check-ported-artifacts.sh 2>&1 | grep -q '^OK: '; then SIBLINGS_HERE=yes; fi
check_with_siblings() {
    if [ "$SIBLINGS_HERE" = yes ]; then check "$1" "$2" "$3"
    else check "$1 (not run: no sibling checkouts here)" "unmeasurable" "unmeasurable"; fi
}

REAL_OUT="$("./$TARGET" 2>&1)"; REAL_CODE=$?
check_with_siblings "every real port here is accounted for" "$REAL_CODE" "0"
check_with_siblings "and none of them has drifted" "$(counts "$REAL_OUT" '^DRIFTED:')" "0"

MINE="$(printf '%s' "$REAL_OUT" | grep -E '^(IN STEP|ADAPTED|DIVERGED|DRIFTED|EDITED SINCE IT WAS PORTED|AUTHORISATION EXPIRED|CANNOT MEASURE): ' | sed -E 's/^[A-Z ]+: //' | sed 's/ .*//' | sort -u)"
THEIRS="$(./scripts/check-ported-artifacts.sh 2>&1 | grep -E '^(OK|NOT ON MAIN|COMMIT NOT FOUND|CANNOT MEASURE|UNREADABLE HEADER): ' | sed -E 's/^[A-Z ]+: //' | sed 's/ .*//' | sort -u)"
check_with_siblings "both ported checks find the same set of artifacts" "$MINE" "$THEIRS"
check_with_siblings "and that set is not empty, so the comparison measured something" \
    "$( [ -n "$MINE" ] && echo populated || echo empty)" "populated"

harness_end
