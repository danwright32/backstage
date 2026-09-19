#!/bin/bash
# The script role inventory must be COMPLETE in both directions (backstage#10).
#
# scripts/lib/script-roles.tsv says what runs each script here, and
# scripts/check-ci-workflow.sh reads it to refuse a check that a workflow runs
# while the inventory calls it something a person runs on demand. Nothing held
# the inventory to the scripts actually on disk.
#
# A guard driven by a hand written registry checks only what the registry lists,
# so anything missing from it is exempt from the check meant to catch it (L96).
# Add a script tomorrow and forget its row and it is not flagged: it is
# invisible, which reads exactly like being fine.
#
# The origin repository does not have this gap. There, two completeness rules
# read the same inventory through scripts/lib/script-roles.sh. This repository
# ported the reader and the inventory without either rule, so the data arrived
# and the enforcement did not.
#
# BOTH HALVES MATTER, and they are different faults with different remedies
# (L11). A script with no row is an exemption nobody chose. A row naming no file
# is a stale claim, and it is the half that reads as maintained precisely
# because somebody once wrote it.
#
# THE PARSING IS THE LIBRARY'S, NOT A SECOND COPY. `roles_paths` and
# `scripts_on_disk` are the same functions check-ci-workflow.sh asks its
# question through, so the two rules cannot come to disagree about what a row is
# or what counts as a script (L370). They are pointed at a fixture by setting
# their two inputs as locals, which bash scopes dynamically, so nothing here
# reaches the real inventory except the case that means to.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. "$(dirname "$0")/lib/test-harness.sh"
harness_begin "script roles inventory tests" 12

TARGET="scripts/lib/script-roles.tsv"
require_target "$TARGET"
require_target "scripts/lib/script-roles.sh"
. "$(dirname "$0")/lib/script-roles.sh"
harness_temp_dir WORK

# On disk with no row: an exemption nobody chose.
missing_rows() {
    local SCRIPT_ROLES_TSV="$1" SCRIPTS_DIR="$2"
    comm -23 <(scripts_on_disk) <(roles_paths)
}

# A row naming no file: a stale claim about a script that is gone.
stale_rows() {
    local SCRIPT_ROLES_TSV="$1" SCRIPTS_DIR="$2"
    comm -13 <(scripts_on_disk) <(roles_paths)
}

names() { if printf '%s' "$1" | grep -qFx "$2"; then echo yes; else echo no; fi; }
count() { printf '%s' "$1" | grep -c . || true; }

REAL_TSV="$PWD/scripts/lib/script-roles.tsv"
REAL_DIR="$PWD/scripts"

# ---------------------------------------------------------------------------
# THE REAL TREE, which is what this rule exists to hold. It is asserted first so
# that a run reading this file knows the fixtures below are calibrated against
# the repository as it actually is, rather than against a shape chosen to make
# them fire (L48).
check "every script under scripts/ carries a row" "$(missing_rows "$REAL_TSV" "$REAL_DIR")" ""
check "every row names a script that is there" "$(stale_rows "$REAL_TSV" "$REAL_DIR")" ""

# TWO EMPTY LISTS PARTITION PERFECTLY. A comparison whose sides are both empty
# agrees about everything and has measured nothing, and that is the state this
# suite would silently reach the day either reader stopped working (L98, L345).
check "the disk side of that comparison was not empty" \
    "$( [ "$(count "$(SCRIPTS_DIR="$REAL_DIR" scripts_on_disk)")" -gt 0 ] && echo populated || echo empty)" "populated"
check "the inventory side of that comparison was not empty" \
    "$( [ "$(count "$(SCRIPT_ROLES_TSV="$REAL_TSV" roles_paths)")" -gt 0 ] && echo populated || echo empty)" "populated"

# ---------------------------------------------------------------------------
# A SCRIPT WITH NO ROW. The fixture is a copy of the real tree with one file
# added, so what fires is the addition and not the emptiness of the tree.
FIX="$WORK/tree"
mkdir -p "$FIX"
cp -R "$REAL_DIR" "$FIX/scripts"
printf '#!/bin/bash\necho undeclared\n' > "$FIX/scripts/check-undeclared.sh"
chmod +x "$FIX/scripts/check-undeclared.sh"

OUT="$(missing_rows "$REAL_TSV" "$FIX/scripts")"
check "a script with no row is refused" "$( [ -n "$OUT" ] && echo refused || echo allowed)" "refused"
check "and it is named, so the remedy is the row to write" "$(names "$OUT" "check-undeclared.sh")" "yes"

# A .py SCRIPT COUNTS TOO. The rules this inventory replaced matched `check-*.sh`
# alone, which is how a python check ended up run by nothing at all, so the case
# has its own fixture rather than riding on the shell one.
printf '#!/usr/bin/env python3\nprint("hi")\n' > "$FIX/scripts/check-undeclared.py"
OUT="$(missing_rows "$REAL_TSV" "$FIX/scripts")"
check "a python script with no row is refused too" "$(names "$OUT" "check-undeclared.py")" "yes"

# git-hooks/ IS OUT OF SCOPE, and that is the inventory's own boundary rather
# than an exemption written here: a hook is installed, not run as a check.
mkdir -p "$FIX/scripts/git-hooks"
printf '#!/bin/bash\nexit 0\n' > "$FIX/scripts/git-hooks/pre-push"
printf '#!/bin/bash\nexit 0\n' > "$FIX/scripts/git-hooks/helper.sh"
OUT="$(missing_rows "$REAL_TSV" "$FIX/scripts")"
check "a file under git-hooks/ is not demanded of the inventory" \
    "$(names "$OUT" "git-hooks/helper.sh")" "no"

# ---------------------------------------------------------------------------
# A ROW NAMING NO FILE. The other half, and the one that reads as maintained:
# somebody wrote it, so it looks like a decision rather than a leftover.
STALE_TSV="$WORK/stale.tsv"
cp "$REAL_TSV" "$STALE_TSV"
printf 'check-deleted-long-ago.sh\tgated\tA row left behind by a deletion.\n' >> "$STALE_TSV"

OUT="$(stale_rows "$STALE_TSV" "$REAL_DIR")"
check "a row naming no file is refused" "$( [ -n "$OUT" ] && echo refused || echo allowed)" "refused"
check "and that row is named" "$(names "$OUT" "check-deleted-long-ago.sh")" "yes"

# ---------------------------------------------------------------------------
# BOTH AT ONCE, because a run holding one fault must still report the other. A
# report that stops at the first finding turns a second, unrelated one into work
# nobody knows about until the first is fixed.
MISS="$(missing_rows "$STALE_TSV" "$FIX/scripts")"
STALE="$(stale_rows "$STALE_TSV" "$FIX/scripts")"
check "a tree with both faults still names the undeclared script" \
    "$(names "$MISS" "check-undeclared.sh")" "yes"
check "and still names the stale row" "$(names "$STALE" "check-deleted-long-ago.sh")" "yes"

harness_end
