#!/bin/bash
# Ported-From: danwright32/ovation scripts/test-check-ported-artifacts.sh @ 65e986c23c50d6a598e1dbb9aff5fbb923eb6908
# Ported-Adapted: 83581f33ff71b0b882e55a6fe5cee544bda4408608411d440fb4a6a377a7f49f
#
# Ported on 2026-09-17 by backstage#2. Do not edit this copy to fix a fault
# that is also in the origin: fix it there and re-port, or the two silently
# diverge and the shared definition stops being shared (L263). Every constant
# was re-checked against what backstage needs rather than inherited (L501).
# The seam names are the one deliberate difference, since an environment
# variable named for another product would be read by nothing here.
# The ported artifact check must report a port made from a commit that is not on
# its sibling's main, must say CANNOT MEASURE when the sibling repository is not
# on this machine, and must never report either of those as a pass.
#
# Ovation ports at least eleven files one line at a time from Downbeat and
# Overture (implementation plan 0.4.6). A clone copies the pattern AS FIRST
# WRITTEN, including every value already corrected in the original, and the
# clone's own note that it follows a proven pattern is what makes it read as safe
# (L501). This plan already caught one instance of exactly that in itself: an
# earlier draft ported Downbeat's identity guard as it stood before L217
# corrected it.
#
# Every outcome the check's contract enumerates is PRODUCED here, not merely
# described (L151), and each assertion names the specific outcome rather than
# accepting any failure (L140).
#
# The two that matter most and are easiest to get wrong:
#
#   CANNOT MEASURE must never be a pass. A checker that reports green because it
#   could not find the repository it was meant to check is indistinguishable from
#   one that checked everything (L98), and the green is then read as confirmation.
#
#   FINDING NOTHING must be its own outcome. Ovation has zero ported files today,
#   so a check that exits 0 on an empty tree would report success for months and
#   be trusted by the time it matters (L98, L182).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. "$(dirname "$0")/lib/test-harness.sh"
harness_begin "ported artifact check tests" 35

TARGET="scripts/check-ported-artifacts.sh"
require_target "$TARGET"

# Everything below runs against throwaway repositories in a temp directory. The
# check only ever reads, so the risk is not that it writes somewhere real but
# that it READS a real sibling and reports about it. Section 6 proves the seam is
# honoured rather than assuming it (L322).
# Created, guarded against a failed mktemp, and removed by the harness on every
# exit path. The suite never writes an rm of its own (ovation#19).
harness_temp_dir WORK

# A stand-in sibling: a real git repo with a main branch and a second commit on a
# branch that was never merged.
SIB="$WORK/roots/downbeat"
mkdir -p "$SIB"
(
    cd "$SIB" || exit 1
    git init -q -b main
    git config user.email t@t; git config user.name t
    git remote add origin https://github.com/danwright32/downbeat.git
    echo one > f.txt; git add f.txt; git commit -qm one
    git checkout -qb unmerged
    echo two > f.txt; git add f.txt; git commit -qm two
    git checkout -qm main 2>/dev/null || git checkout -q main
) >/dev/null 2>&1
ON_MAIN="$(cd "$SIB" && git rev-parse main)"
NOT_ON_MAIN="$(cd "$SIB" && git rev-parse unmerged)"

# The tree of "Ovation files" the check scans. A fresh one per case, so no case
# can pass because of a file another case left behind.
new_tree() { local d="$WORK/tree$1"; [ -n "$WORK" ] || exit 1; rm -rf "$d"; mkdir -p "$d"; echo "$d"; }
port_header() { printf '# Ported-From: %s %s @ %s\n' "$1" "$2" "$3"; }

run_check() {
    BACKSTAGE_SIBLING_SEARCH_ROOTS="$WORK/roots" \
    BACKSTAGE_PORT_SCAN_ROOT="$1" \
        "./$TARGET" 2>&1
}

# 1. A port whose recorded commit IS on the sibling's main. The only case that
#    may exit 0, and it has to be produced or every refusal below is satisfied by
#    a check that refuses everything.
T1="$(new_tree 1)"
port_header "danwright32/downbeat" "scripts/install-git-hooks.sh" "$ON_MAIN" > "$T1/ported.sh"
OUT1="$(run_check "$T1")"; ST1=$?
check "a port from a commit on the sibling's main passes" "$ST1" "0"
check "and it says how many artifacts it actually examined" \
    "$(printf '%s' "$OUT1" | grep -c "1 ported artifact")" "1"

# 2. A port whose recorded commit is on a branch that was never merged. This is
#    the defect the check exists to find.
T2="$(new_tree 2)"
port_header "danwright32/downbeat" "scripts/install-git-hooks.sh" "$NOT_ON_MAIN" > "$T2/ported.sh"
OUT2="$(run_check "$T2")"; ST2=$?
check "a port from an unmerged commit is REPORTED" "$ST2" "1"
check "and it is named as not being on main" \
    "$(printf '%s' "$OUT2" | grep -c "NOT ON MAIN")" "1"
check "and it names the file it found the header in" \
    "$(printf '%s' "$OUT2" | grep -c "ported.sh")" "1"

# 3. A sibling repository that is not on this machine. CANNOT MEASURE, never a
#    pass, and distinct from case 2 so a missing checkout can never be read as a
#    clean port (L11).
T3="$(new_tree 3)"
port_header "danwright32/nosuchrepo" "some/file.sh" "$ON_MAIN" > "$T3/ported.sh"
OUT3="$(run_check "$T3")"; ST3=$?
check "an absent sibling repository does not pass" "$([ "$ST3" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "and it says CANNOT MEASURE" \
    "$(printf '%s' "$OUT3" | grep -c "CANNOT MEASURE")" "1"
check "and it does NOT report it as not being on main" \
    "$(printf '%s' "$OUT3" | grep -c "NOT ON MAIN")" "0"
check "and its exit code is distinct from the not-on-main one" \
    "$([ "$ST3" != "$ST2" ] && echo distinct || echo same)" "distinct"

# 4. The sibling is present but the recorded commit is not in it. A different
#    cause again: the repo was found, the commit was not.
T4="$(new_tree 4)"
port_header "danwright32/downbeat" "scripts/install-git-hooks.sh" "0000000000000000000000000000000000000000" > "$T4/ported.sh"
OUT4="$(run_check "$T4")"; ST4=$?
check "an unknown commit in a present sibling does not pass" \
    "$([ "$ST4" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "and it says the commit is unknown rather than not on main" \
    "$(printf '%s' "$OUT4" | grep -c "COMMIT NOT FOUND")" "1"

# 5. No ported artifacts at all. Ovation's real state today, and the one a naive
#    check reports as success for months (L98).
T5="$(new_tree 5)"
echo "a file with no port header" > "$T5/plain.sh"
OUT5="$(run_check "$T5")"; ST5=$?
check "finding no ported artifacts is NOT a pass" \
    "$([ "$ST5" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "and it says so in its own words, naming the emptiness" \
    "$(printf '%s' "$OUT5" | grep -c "NO PORTED ARTIFACTS")" "1"
check "and it never claims anything was verified" \
    "$(printf '%s' "$OUT5" | grep -ci "all ported artifacts verified")" "0"

# 6. The search-root seam is honoured. `danwright32/overture` is genuinely on
#    this machine, so if the check ignored the seam and searched the real estate
#    it would resolve it and answer about a real repository. It must not.
T6="$(new_tree 6)"
port_header "danwright32/overture" "mac/project.yml" "$ON_MAIN" > "$T6/ported.sh"
OUT6="$(run_check "$T6")"; ST6=$?
check "a repo outside the search roots is not resolved from the real estate" \
    "$(printf '%s' "$OUT6" | grep -c "CANNOT MEASURE")" "1"
check "and the seam being honoured means it did not pass" \
    "$([ "$ST6" -ne 0 ] && echo nonzero || echo zero)" "nonzero"

# 7. A header that is present but malformed. An operation that finds its target
#    by matching text reports success when it matches nothing (L100), so a header
#    the check cannot parse must be refused by name rather than skipped into the
#    "no artifacts" or the "all clear" bucket.
T7="$(new_tree 7)"
echo "# Ported-From: this is not three fields" > "$T7/ported.sh"
OUT7="$(run_check "$T7")"; ST7=$?
check "a malformed port header does not pass" \
    "$([ "$ST7" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "and it is refused as unparseable rather than ignored" \
    "$(printf '%s' "$OUT7" | grep -c "UNREADABLE HEADER")" "1"
check "and it is not reported as no artifacts having been found" \
    "$(printf '%s' "$OUT7" | grep -c "NO PORTED ARTIFACTS")" "0"

# 8. Comment styles. Ovation ports shell, yaml and Swift, so the marker must be
#    found behind '#' and '//' alike. A check that only understood one would
#    silently examine none of the Swift ports and report the rest as everything.
T8="$(new_tree 8)"
printf '// Ported-From: %s %s @ %s\n' "danwright32/downbeat" "Persistence/StoreSchemaGuard.swift" "$ON_MAIN" > "$T8/Guard.swift"
OUT8="$(run_check "$T8")"; ST8=$?
check "a Swift style comment header is found" "$ST8" "0"
check "and it counted the Swift file as an artifact" \
    "$(printf '%s' "$OUT8" | grep -c "1 ported artifact")" "1"

# 9. A file that TALKS ABOUT port headers is not a ported artifact. The check has
#    to name its own marker in order to search for it, so it matches itself, its
#    own test, and every document describing the convention (L245). Found by
#    running it against the real repository, which no fixture case could reach,
#    because every case above scans an isolated temp tree.
#
#    The rule is the reason, not a list of filenames (L362): a real port header
#    is a HEADER, sitting at the start of its comment. Prose about one is
#    indented inside a block, so it is not a header and must not be counted.
T9="$(new_tree 9)"
{
    echo "# Some documentation about the convention:"
    echo "#"
    echo "#     Ported-From: <owner>/<repo> <path in that repo> @ <commit>"
    echo "#"
    echo "# and some more prose after it."
} > "$T9/doc.sh"
OUT9="$(run_check "$T9")"; ST9=$?
check "indented prose describing a port header is not counted as an artifact" \
    "$(printf '%s' "$OUT9" | grep -c "UNREADABLE HEADER")" "0"
check "and a tree holding only such prose reports no artifacts, not a failure" \
    "$ST9" "3"

# 10. The real repository, scanned with the real default roots. This is the case
#     the seam deliberately hides from every case above, and it is where case 9's
#     defect actually lived.
#
#     INVERTED 2026-09-05, in the same change that consumed it (L373). It used to
#     assert that Ovation had NO ported artifacts, which was true for about an
#     hour: project.yml then landed carrying a real header, ported from
#     Overture's mac/project.yml. A test whose premise is that a change has not
#     yet been made is consumed by that change shipping, and left behind it goes
#     permanently red for a reason that looks exactly like a real defect.
#
#     What it asserts now is the stronger thing anyway: the real ports resolve
#     against the real siblings, through the real default search roots, which no
#     other case can reach.
OUT10="$(BACKSTAGE_PORT_SCAN_ROOT="$PWD" "./$TARGET" 2>&1)"; ST10=$?

# A MACHINE WITHOUT THE SIBLINGS CANNOT ANSWER THIS, AND MUST NOT REPORT RED.
#
# These two cases and case 11 are the only ones that use the real default search
# roots, which is their whole point, and that makes them the only ones that need
# the sibling checkouts to actually be on the disk. A fresh clone, Dan's second
# Mac and a CI runner have none, and a failure there is indistinguishable from a
# genuinely stale port (L411). Found by the first CI run this repository ever had
# (ovation#143): four red assertions about ports that are perfectly fine.
#
# THE LIMIT, SAID RATHER THAN LEFT TO BE FOUND: the signal is the check's own
# report, so a check that wrongly believed the siblings were missing would turn
# these into skips rather than failures. Case 3 above stages that path against a
# root of its own and is what keeps it honest, and on the machine that has the
# siblings, which is the one these cases were written for, they run at full
# strength.
SIBLINGS_HERE=yes
if printf '%s' "$OUT10" | grep -q "is not on this machine"; then
    SIBLINGS_HERE=no
    echo "UNMEASURABLE HERE: the sibling checkouts are not on this machine, so the"
    echo "    cases that verify the real ports against them are not being run."
fi
# Said out loud above and counted the same either way, so the suite's own count
# cannot silently shrink on a machine that skips them (L288).
check_with_siblings() {
    if [ "$SIBLINGS_HERE" = yes ]; then
        check "$1" "$2" "$3"
    else
        check "$1 (not run: no sibling checkouts here)" "unmeasurable" "unmeasurable"
    fi
}

# RE-DERIVED FOR THIS REPOSITORY, not inherited (L501). The origin asserts here
# that ITS one real port, Overture's mac/project.yml, is reported OK. backstage
# has no such file, so that assertion arrived permanently red for a reason that
# looks exactly like a real defect. The PURPOSE of the case is what carries over:
# the real ports, resolved against the real siblings, through the real default
# search roots, which no other case can reach. What names a specific artifact is
# re-derived from what this repository actually ports.
check_with_siblings "scanning backstage itself verifies its real ports against the real siblings" \
    "$ST10" "0"
check_with_siblings "and the shared test harness is one of them, reported OK" \
    "$(printf '%s' "$OUT10" | grep -c '^OK: scripts/lib/test-harness.sh')" "1"
check "and it still does not match its own marker" \
    "$(printf '%s' "$OUT10" | grep -c "UNREADABLE HEADER")" "0"
check "and it does not report the repository as empty now that a port exists" \
    "$(printf '%s' "$OUT10" | grep -c "NO PORTED ARTIFACTS")" "0"

# ---------------------------------------------------------------------------
# 11. THE ENVIRONMENT A GIT HOOK RUNS IN. This check's whole job is to ask other
# repositories about themselves, and `git -C <other repo>` is NOT enough to do
# that: an inherited GIT_DIR beats the -C, so every sibling answers with THIS
# repository's origin, matches no slug, and is reported as not being on the
# machine while sitting right there.
#
# git EXPORTS GIT_DIR to its hooks, which is exactly where this check runs. From
# the primary checkout it survives by luck, because that GIT_DIR is the relative
# `.git`, and a relative GIT_DIR beside `-C /path/to/sibling` resolves to the
# sibling's own .git. From a WORKTREE it is absolute, and every artifact reports
# CANNOT MEASURE. Found on 2026-09-08 by a push refused for nine unmeasurable
# ports, with all nine siblings present and the same command passing by hand.
#
# The fixture sets the absolute form, because that is the one that breaks, and
# asserts the check reaches the same verdict it reaches with a clean
# environment: not merely that it passes, but that it says the same thing.
OUT11="$(GIT_DIR="$PWD/.git" GIT_WORK_TREE="$PWD" \
    BACKSTAGE_PORT_SCAN_ROOT="$PWD" "./$TARGET" 2>&1)"; ST11=$?
check_with_siblings "an inherited GIT_DIR does not stop the siblings being resolved" "$ST11" "0"
# This one is a comparison of two runs on the SAME machine, so it holds whether
# or not the siblings are here: both sides move together.
check "and the verdict is the same one a clean environment reaches" \
    "$(printf '%s' "$OUT11" | tail -1)" "$(printf '%s' "$OUT10" | tail -1)"
check_with_siblings "and nothing is reported as missing from a machine it is on" \
    "$(printf '%s' "$OUT11" | grep -c "is not on this machine")" "0"

# ---------------------------------------------------------------------------
# TWO KINDS OF CANNOT MEASURE, THE SAME SPLIT THE GATE NOW READS (ovation#135).
#
# A sibling repository that is NOT ON THIS MACHINE is a question nothing here
# could ever have answered: a fresh clone, Dan's second Mac and a CI runner are
# all in that state, and the gate lets them push while naming what went
# unchecked. A sibling that IS here and cannot answer, because it holds no main
# to compare against or does not contain the commit, is a fault on this machine,
# and the gate refuses.
#
# They were one code, so either every machine without the siblings was refused or
# a genuinely broken sibling was waved through. There is no third position while
# the two share a verdict (L11, L260).
ABSENT_COMMIT="0123456789abcdef0123456789abcdef01234567"

T20="$(new_tree 20)"
port_header "danwright32/nosuchrepo" "scripts/x.sh" "$ON_MAIN" > "$T20/ported.sh"
OUT20="$(run_check "$T20")"; ST20=$?
check "a sibling that is not on this machine is the never equipped outcome" "$ST20" "2"

T21="$(new_tree 21)"
port_header "danwright32/downbeat" "scripts/x.sh" "$ABSENT_COMMIT" > "$T21/ported.sh"
OUT21="$(run_check "$T21")"; ST21=$?
check "a sibling that IS here and does not hold the commit is the other outcome" "$ST21" "4"
check "and it says the sibling was present, so the fault is here" \
    "$(printf '%s' "$OUT21" | grep -c 'COMMIT NOT FOUND')" "1"

# BOTH AT ONCE: the refusing one wins, because a run that must be refused cannot
# be softened by an unrelated question nothing could answer.
T22="$(new_tree 22)"
port_header "danwright32/nosuchrepo" "scripts/x.sh" "$ON_MAIN" > "$T22/absent.sh"
port_header "danwright32/downbeat" "scripts/x.sh" "$ABSENT_COMMIT" > "$T22/broken.sh"
OUT22="$(run_check "$T22")"; ST22=$?
check "a run holding both outcomes reports the one that refuses" "$ST22" "4"
check "and the summary counts them separately rather than as one number" \
    "$(printf '%s' "$OUT22" | grep -cE '1 not on this machine.*1 unmeasurable|1 unmeasurable.*1 not on this machine')" "1"

harness_end
