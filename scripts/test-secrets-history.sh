#!/bin/bash
# The secrets guard must read the HISTORY, not only the working tree (backstage#11).
#
# This repository is PUBLIC for the whole build and its entire subject matter is
# a Google OAuth client. Deleting a secret from a public repository does not
# remove it: it stays readable in the history, in forks, and in anything that
# cloned or cached it. So the one case where the working tree guard matters most,
# a credential that WAS committed and has since been tidied away, is the exact
# case it cannot see.
#
# THE GAP BETWEEN THE TWO GUARDS IS THE FINDING, so the central case asserts both
# halves on ONE fixture: the working tree guard passes it and this one refuses
# it. Asserting only that this one refuses would not show that anything was
# missing before (L159).
#
# NO FIXTURE CARRIES A VALUE THAT COULD BE REAL. Each pattern is assembled from
# pieces at run time, so this file holds no literal run either guard would match,
# and a suite holding a real credential would publish it (L155, L222).
#
# EVERY FIXTURE STAGES BY NAME. An unscoped add sweeps up whatever else is in the
# directory, and a fixture that grew a stray file would commit it into the blob
# set this suite then makes assertions about.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. "$(dirname "$0")/lib/test-harness.sh"
harness_begin "secrets history tests" 20

TARGET="scripts/check-secrets-history.sh"
WORKING_TREE_GUARD="scripts/check-secrets.sh"
require_target "$TARGET"
require_target "$WORKING_TREE_GUARD"
require_target "scripts/lib/secret_rules.py"
harness_temp_dir WORK

CLIENT_SECRET="GOCSPX-""cccccccccccccccccccccccc"
REAL_MAILBOX="someone""@""a-real-looking-domain.com"

says() { if printf '%s' "$1" | grep -qF "$2"; then echo yes; else echo no; fi; }

# A throwaway checkout. The identity is given on the command rather than written
# into a config, because the harness clears git's environment for every suite and
# a fixture that set one globally would author every later commit on this machine.
new_repo() {
    # THE GUARD BEFORE THE rm, as every other fixture here carries it. `set -u`
    # does not catch an EMPTY variable, and an rm -rf on a path built from one
    # runs at the filesystem root (L5).
    [ -n "${WORK:-}" ] || exit 1
    local d="$WORK/$1"
    rm -rf "$d"; mkdir -p "$d"
    ( cd "$d" && git init -q -b main >/dev/null 2>&1 ) || return 1
    printf '%s\n' "$d"
}
as_fixture() {
    local d="$1"; shift
    ( cd "$d" && git -c user.email=fixture@fixture.invalid -c user.name=fixture "$@" )
}
commit_paths() {
    local d="$1" message="$2"; shift 2
    ( cd "$d" && git add -- "$@" ) || return 1
    as_fixture "$d" commit -q -m "$message"
}
remove_and_commit() {
    local d="$1" message="$2" path="$3"
    ( cd "$d" && git rm -q -- "$path" ) || return 1
    as_fixture "$d" commit -q -m "$message"
}

OUT=""; CODE=0
run_history() { OUT="$("$TARGET" "$1" 2>&1)"; CODE=$?; }
TREE_OUT=""; TREE_CODE=0
run_working_tree() { TREE_OUT="$("$WORKING_TREE_GUARD" "$1" 2>&1)"; TREE_CODE=$?; }

# ---------------------------------------------------------------------------
# THE CASE THE WHOLE CHECK EXISTS FOR: committed, then tidied away.
D="$(new_repo tidied-away)"
printf 'let k = "%s"\n' "$CLIENT_SECRET" > "$D/Secrets.swift"
printf 'import Foundation\n' > "$D/Ordinary.swift"
commit_paths "$D" "the mistake" Secrets.swift Ordinary.swift
remove_and_commit "$D" "tidy it away" Secrets.swift

run_working_tree "$D"
check "the working tree guard passes a tree the secret has been deleted from" "$TREE_CODE" "0"
run_history "$D"
check "the history guard refuses the same repository" \
    "$( [ "$CODE" -eq 1 ] && echo refused || echo "exit $CODE" )" "refused"
check "and it names the path the blob sat at" "$(says "$OUT" "Secrets.swift")" "yes"
check "and it names which rule fired" "$(says "$OUT" "oauth-client-secret")" "yes"
check "and it places the blob in a commit" "$(says "$OUT" "commit ")" "yes"
check "and it never prints the value" "$(says "$OUT" "$CLIENT_SECRET")" "no"

# THE REMEDY MUST BE THE REAL ONE. A message telling somebody to rewrite history
# names an action that does not change the state they are in: anything that was
# public has been fetchable for as long as it was there (L111).
check "and the remedy is to rotate the credential" "$(says "$OUT" "ROTATE")" "yes"
check "and it does not tell anyone that rewriting history fixes it" \
    "$(says "$OUT" "not to rewrite")" "yes"

# ---------------------------------------------------------------------------
# WHAT IT MUST PRESERVE (L104). A repository that never held one is clean, and it
# says how much it read, so a run that examined nothing cannot read as this one.
D="$(new_repo clean-history)"
printf 'import Foundation\n' > "$D/Ordinary.swift"
printf 'contact: nobody@example.com\n' > "$D/README.md"
commit_paths "$D" "ordinary work" Ordinary.swift README.md
run_history "$D"
check "a repository that never held a credential is accepted" "$CODE" "0"
check "and it says how many blobs it actually read" "$(says "$OUT" "blob(s)")" "yes"

# ---------------------------------------------------------------------------
# THE SAME RULES AS THE WORKING TREE GUARD, which is the point of the shared
# library: two guards each deciding what a secret is are two rules that drift
# (L370). A real mailbox in history is refused, and an address on a reserved
# documentation domain is not, exactly as the other guard decides it.
D="$(new_repo mailbox-in-history)"
printf 'to: %s\n' "$REAL_MAILBOX" > "$D/Fixture.swift"
commit_paths "$D" "a real mailbox" Fixture.swift
remove_and_commit "$D" "tidied" Fixture.swift
run_history "$D"
check "a real mailbox in history is refused by the same rule" "$(says "$OUT" "mailbox")" "yes"
check "and the address is never printed" "$(says "$OUT" "$REAL_MAILBOX")" "no"

D="$(new_repo reserved-in-history)"
printf 'to: nobody@example.org\nalso: a@fixture.invalid\n' > "$D/Fixture.swift"
commit_paths "$D" "documentation addresses" Fixture.swift
run_history "$D"
check "a reserved documentation domain in history is not a finding" "$CODE" "0"

# ---------------------------------------------------------------------------
# NOTHING TO EXAMINE IS NOT A PASS (L98). A repository with no commits has no
# history, and a run over it that printed "clean" would be believed.
D="$(new_repo no-commits)"
run_history "$D"
check "a repository with no commits is refused, not passed" "$CODE" "2"
check "and it says there was nothing committed to read" "$(says "$OUT" "no committed blob")" "yes"

# A directory that is not a checkout cannot be asked this question at all, and
# that is a different outcome from a history that came back clean (L11).
D="$WORK/not-a-checkout"; mkdir -p "$D"
run_history "$D"
check "a directory that is not a checkout is refused" "$CODE" "2"

# ---------------------------------------------------------------------------
# A BLOB NOTHING READ IS NOT A CLEAN ONE. A scanner that gives up on something
# and says nothing reads as clean (L329), so an oversized blob is named and the
# run does not report success.
D="$(new_repo oversized-blob)"
printf 'import Foundation\n' > "$D/Ordinary.swift"
dd if=/dev/zero of="$D/huge.bin" bs=1048576 count=11 >/dev/null 2>&1
commit_paths "$D" "something large" Ordinary.swift huge.bin
run_history "$D"
check "an oversized blob is named rather than skipped quietly" "$(says "$OUT" "NOT READ")" "yes"
check "and the run does not report success over it" \
    "$( [ "$CODE" -ne 0 ] && echo withheld || echo passed )" "withheld"

# ---------------------------------------------------------------------------
# WITHOUT ITS RULES IT REFUSES, and with the code that means UNMEASURABLE rather
# than the one that means a secret was found (L11). The fixture is a copy beside
# an empty lib, so the real library is never moved.
NOLIB="$WORK/no-library"
mkdir -p "$NOLIB/lib"
cp "$TARGET" "$NOLIB/check-secrets-history.sh"
OUT="$("$NOLIB/check-secrets-history.sh" "$D" 2>&1)"; CODE=$?
check "without its rules it refuses rather than reporting a finding" "$CODE" "2"
check "and it names the library that could not be read" \
    "$(says "$OUT" "secret_rules.py")" "yes"

harness_end
