#!/bin/bash
# Assert that every ported file still matches what it was when it was ported.
#
# backstage#9. scripts/check-ported-artifacts.sh verifies that the commit a
# ported file NAMES is still on its origin's main. It never compares the ported
# file's CONTENT against that commit, so a copy edited here drifts from its
# origin in silence and that check stays green for ever.
#
# WHY IT MATTERS MORE THAN IT SOUNDS. Every ported header in this repository
# says, in as many words, "do not edit this copy to fix a fault that is also in
# the origin: fix it there and re-port". That sentence was enforced by nothing. A
# constraint recorded only as a comment is enforced by nothing, and sitting there
# makes it read as binding (L407).
#
# IT HAS ALREADY HAPPENED DELIBERATELY, ONCE. scripts/check-ci-workflow.sh
# diverges from Ovation's copy on purpose, pending ovation#399, and the only
# record of it was a paragraph in its header. If ovation#399 lands and nobody
# remembers to re-port, the divergence becomes permanent and invisible; if a
# second one appears by accident tomorrow, it looks exactly like the first.
#
# ---------------------------------------------------------------------------
# WHAT THE REAL POPULATION LOOKS LIKE, measured rather than assumed (L147).
#
# Measured on 2026-09-19, before the rule was written rather than after: of the
# 23 ported artifacts here, 8 were the origin's file with one block of
# backstage's own comments inserted, and 15 had been DELIBERATELY ADAPTED when
# they were ported. Sources/BackstageGoogle/GmailAuthManager.swift lists eight
# such changes in its own header, because the origin is one app's sign in and
# this is a package three apps share. A check offering only "identical,
# authorised, or drifted" would have refused 15 correct files on its first run,
# which is the shape of guard that gets switched off rather than fixed. The
# numbers are what that day's tree held; the summary line below is what is true
# now, and nothing here should be read as a live count.
#
# So there are FOUR outcomes, and the distinction that matters is not "does this
# differ from the origin" but "has this changed since it was ported" (L11):
#
#   IN STEP     the origin's file with ONE contiguous block of comment lines
#               inserted, holding the Ported-From header. Nothing to record:
#               the origin and the commit pin it exactly.
#   ADAPTED     it differs on purpose, the header says how, and a recorded
#               digest says what it looked like when that was decided. Matching
#               that digest is what makes a later edit visible.
#   DIVERGED    an ADAPTED file whose difference carries a fix PENDING at the
#               origin, authorised by an issue that must still be OPEN. An
#               authorisation that outlives its reason is not an authorisation.
#   DRIFTED     anything else. Refused.
#
# The digest covers the whole local file with the recorded digest's own value
# blanked, so the line can hold the digest of the file it sits in.
#
# ---------------------------------------------------------------------------
# WHY IT IS A SECOND SCRIPT rather than an edit to check-ported-artifacts.sh:
# that file is itself ported, and adding this to it would introduce exactly the
# divergence this exists to report. The cost is two pieces of code that each find
# the ported artifacts, and it is paid down by scripts/test-ported-content.sh,
# which asserts the two find the SAME set rather than leaving them to drift
# unobserved (L582).
#
# Exit codes, so a caller can tell them apart without parsing text:
#
#     0  every artifact accounted for, and there was at least one
#     1  at least one DRIFTED or EXPIRED AUTHORISATION
#     2  at least one sibling repository is not on this machine
#     3  no ported artifacts found at all
#     4  a fault on THIS machine: no digest tool, a commit the sibling does not
#        hold, or an authorisation whose state could not be read
#
# Seams, so the suite never reads a real sibling repository (L2):
#     BACKSTAGE_PORT_SCAN_ROOT         where to look for ported files
#     BACKSTAGE_SIBLING_SEARCH_ROOTS   colon separated roots to resolve siblings in
#     BACKSTAGE_ISSUE_STATE            a command answering OPEN or CLOSED for an
#                                      issue, so the suite never asks GitHub
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN_ROOT="${BACKSTAGE_PORT_SCAN_ROOT:-$REPO_ROOT}"

# SOURCED, OR REFUSED. Bash's `.` on a missing file prints to stderr, returns non
# zero and CARRIES ON, so without this the check runs to its summary with whole
# rules absent and exits 0 (L488, backstage#7).
LIB="$(dirname "${BASH_SOURCE[0]}")/lib/repo-git.sh"
if [ ! -f "$LIB" ]; then
  echo "REFUSED: $LIB is missing, so nothing was checked."
  echo "    Every question this asks of a sibling goes through it."
  exit 4
fi
# shellcheck source=lib/repo-git.sh
. "$LIB"

# Assembled from pieces so this file contains no literal instance of either
# marker it looks for. THIS SCRIPT HAS TO NAME ITS OWN NEEDLES IN ORDER TO SEARCH
# FOR THEM, and an unescaped example here would make it match itself and every
# document describing the convention (L245).
MARKER="Ported""-From:"
ADAPTED="Ported""-Adapted:"
DIVERGENCE="Ported""-Divergence:"
HEADER_RE="^[[:space:]]*(#|//)[[:space:]]?${MARKER}"
ADAPTED_RE="^[[:space:]]*(#|//)[[:space:]]?${ADAPTED}"
DIVERGENCE_RE="^[[:space:]]*(#|//)[[:space:]]?${DIVERGENCE}"

# A DIGEST TOOL OR NOTHING. Both are present on macOS and on an ubuntu runner;
# a machine with neither answers CANNOT MEASURE rather than passing, because a
# check that examined nothing must never read as one that found nothing wrong.
if command -v shasum >/dev/null 2>&1; then
  digest_of_stdin() { shasum -a 256 | cut -d' ' -f1; }
elif command -v sha256sum >/dev/null 2>&1; then
  digest_of_stdin() { sha256sum | cut -d' ' -f1; }
else
  echo "CANNOT MEASURE: neither shasum nor sha256sum is on this machine, so no"
  echo "    recorded digest could be checked. Nothing was verified."
  exit 4
fi

# THE REFUSAL IS WRITTEN HERE. The library's sibling_search_roots used to print
# its own CANNOT MEASURE line; since the re-port of backstage#69 it refuses as
# sibling_root does, with the reason on stderr and nothing on stdout, so a caller
# that only echoed what it captured would print a blank line and exit 2 with no
# remedy named.
if ! SEARCH_ROOTS="$(sibling_search_roots "$REPO_ROOT")"; then
  echo "CANNOT MEASURE: where the sibling checkouts live could not be worked out (see above)."
  echo "    Set BACKSTAGE_SIBLING_SEARCH_ROOTS to the folder holding them."
  exit 2
fi

if [ ! -d "$SCAN_ROOT" ]; then
  echo "CANNOT MEASURE: the scan root does not exist: $SCAN_ROOT"
  exit 2
fi

# The digest of a file with the recorded digest's OWN value blanked, so the line
# carrying it does not change what it describes.
# THE RECORD LINES ARE REMOVED FROM THE DIGEST, not blanked, and that is what
# makes the printed remedy correct. A digest taken over the file as it stands
# WITHOUT the record would stop matching the moment the record line was added,
# so the line the refusal tells a reader to write would be wrong the instant
# they wrote it, and the check would refuse again with a different digest
# (L406). Removing both record lines means adding, editing or deleting either
# one does not change what the digest describes.
#
# THE DELIMITER IS NOT `|`, and that is not a style choice: the pattern contains
# `(#|//)`, so a `|` delimiter ends the expression in the middle of the
# alternation. BSD sed reports "parentheses not balanced", GNU sed reports
# something else, and under `set -uo pipefail` with no -e the failure reaches the
# digest as EMPTY INPUT, whose sha256 is a valid looking constant that every file
# then appears to share (L183, L434).
# The leading backslash before the delimiter is REQUIRED: an address written
# with a custom delimiter is `\%...%`, and `%...%d` without it is not an address
# at all. Written without it, sed fails, the digest is taken over EMPTY input,
# and every file shares the sha256 of nothing, which matches whatever was
# recorded and passes everything.
digest_of() {
  sed -E -e "\%^[[:space:]]*(#|//)[[:space:]]?${ADAPTED}%d" \
         -e "\%^[[:space:]]*(#|//)[[:space:]]?${DIVERGENCE}%d" "$1" | digest_of_stdin
}

# Is the local file the origin's file with ONE contiguous block of comment lines
# inserted? Strict on purpose: a comment added somewhere else in the file is a
# second block, and is drift rather than a ported header.
is_in_step() {
  local origin="$1" local_file="$2" d hunks deletions non_comment
  d="$(diff "$origin" "$local_file")"
  [ -n "$d" ] || return 1
  deletions="$(printf '%s\n' "$d" | grep -cE '^<' || true)"
  [ "$deletions" -eq 0 ] || return 1
  non_comment="$(printf '%s\n' "$d" | grep -E '^>' | sed 's/^> //' \
      | grep -vcE '^[[:space:]]*(#|//)|^[[:space:]]*$' || true)"
  [ "$non_comment" -eq 0 ] || return 1
  hunks="$(printf '%s\n' "$d" | grep -cE '^[0-9]' || true)"
  [ "$hunks" -eq 1 ] || return 1
  printf '%s\n' "$d" | grep -E '^>' | grep -qF "$MARKER"
}

# OPEN, CLOSED, or UNKNOWN. Asked through a seam so the suite never reaches
# GitHub, and UNKNOWN is its own answer rather than either of the other two: a
# state that could not be read is not permission (L345, L42).
issue_state() {
  local slug="$1" number="$2" state
  if [ -n "${BACKSTAGE_ISSUE_STATE:-}" ]; then
    state="$($BACKSTAGE_ISSUE_STATE "$slug" "$number" 2>/dev/null)" || state=""
  else
    command -v gh >/dev/null 2>&1 || { echo UNKNOWN; return; }
    state="$(gh issue view "$number" --repo "$slug" --json state --jq .state 2>/dev/null)" || state=""
  fi
  case "$state" in
    OPEN|open) echo OPEN ;;
    CLOSED|closed) echo CLOSED ;;
    *) echo UNKNOWN ;;
  esac
}

found=0
in_step=0
adapted=0
diverged=0
drifted=0
sibling_absent=0
cannot_measure=0

while IFS= read -r file; do
  line="$(grep -hE "$HEADER_RE" "$file" 2>/dev/null | head -1)"
  [ -n "$line" ] || continue
  found=$((found+1))
  rel="${file#$SCAN_ROOT/}"
  spec="${line#*$MARKER}"
  # shellcheck disable=SC2086
  set -- $spec
  slug="${1:-}"; path="${2:-}"; commit="${4:-}"
  if [ "$#" -ne 4 ] || [ -z "$slug" ] || [ -z "$path" ] || [ -z "$commit" ]; then
    # The header shape is check-ported-artifacts.sh's question, and it refuses
    # on it already. Here it is only a reason this file cannot be compared.
    echo "CANNOT MEASURE: $rel"
    echo "    its header could not be read, so there is nothing to compare against"
    cannot_measure=$((cannot_measure+1))
    continue
  fi

  if ! sibling="$(resolve_sibling "$slug" "$SEARCH_ROOTS")"; then
    echo "CANNOT MEASURE: $rel"
    echo "    the sibling repository $slug is not on this machine"
    sibling_absent=$((sibling_absent+1))
    continue
  fi

  origin="$(mktemp)"
  if ! clean_git -C "$sibling" show "${commit}:${path}" > "$origin" 2>/dev/null; then
    rm -f "$origin"
    echo "CANNOT MEASURE: $rel"
    echo "    $slug does not hold $path at ${commit:0:8}, so the port cannot be compared"
    cannot_measure=$((cannot_measure+1))
    continue
  fi

  recorded="$(grep -hE "$ADAPTED_RE" "$file" 2>/dev/null | head -1 | sed -E "s%.*${ADAPTED}[[:space:]]*%%" | tr -d '[:space:]')"
  actual="$(digest_of "$file")"
  divergence="$(grep -hE "$DIVERGENCE_RE" "$file" 2>/dev/null | head -1 | sed -E "s%.*${DIVERGENCE}[[:space:]]*%%" | tr -d '[:space:]')"
  rm -f "$origin.keep" 2>/dev/null

  if is_in_step "$origin" "$file"; then
    rm -f "$origin"
    if [ -n "$recorded" ]; then
      # A RECORDED DIGEST ON A FILE THAT NEEDS NONE is a claim nothing maintains,
      # and it would go on reading as a considered decision (L346).
      echo "IN STEP, BUT CARRYING A RECORD IT DOES NOT NEED: $rel"
      echo "    it is the origin's file with only the ported header added, so the"
      echo "    origin and the commit already pin it. Delete the ${ADAPTED} line."
      drifted=$((drifted+1))
      continue
    fi
    echo "IN STEP: $rel  ($slug $path @ ${commit:0:8})"
    in_step=$((in_step+1))
    continue
  fi
  rm -f "$origin"

  if [ -z "$recorded" ]; then
    echo "DRIFTED: $rel"
    echo "    it differs from $slug $path @ ${commit:0:8} by more than the ported"
    echo "    header, and nothing here records that as deliberate."
    echo "    If the difference is NOT intended, revert it and re-port."
    echo "    If it IS intended, say how in the header and write this line into it:"
    echo ""
    echo "        # ${ADAPTED} $actual"
    echo ""
    drifted=$((drifted+1))
    continue
  fi

  if [ "$recorded" != "$actual" ]; then
    echo "EDITED SINCE IT WAS PORTED: $rel"
    echo "    it no longer matches the copy recorded when it was adapted, so this"
    echo "    is an edit made to a port rather than at its origin (L263)."
    echo "    If the edit is NOT intended, revert it."
    echo "    If it IS intended, say why in the header and write this line:"
    echo ""
    echo "        # ${ADAPTED} $actual"
    echo ""
    drifted=$((drifted+1))
    continue
  fi

  if [ -z "$divergence" ]; then
    echo "ADAPTED: $rel  (unchanged since it was ported)"
    adapted=$((adapted+1))
    continue
  fi

  # AN AUTHORISATION MUST OUTLIVE NOTHING. A divergence held open by an issue is
  # only authorised while that issue is.
  issue_slug="${divergence%%#*}"
  issue_number="${divergence##*#}"
  case "$(issue_state "$issue_slug" "$issue_number")" in
    OPEN)
      echo "DIVERGED: $rel  (authorised by $divergence, which is open)"
      diverged=$((diverged+1))
      ;;
    CLOSED)
      echo "AUTHORISATION EXPIRED: $rel"
      echo "    it diverges from its origin pending $divergence, and that issue is"
      echo "    CLOSED. Re-port from the origin and delete the ${DIVERGENCE} line,"
      echo "    or, if the divergence is now permanent, say so and name what"
      echo "    authorises it instead."
      drifted=$((drifted+1))
      ;;
    *)
      echo "CANNOT MEASURE: $rel"
      echo "    $divergence authorises its divergence and that issue's state could"
      echo "    not be read, so nothing here can say the authorisation still holds."
      cannot_measure=$((cannot_measure+1))
      ;;
  esac
done < <(grep -rlE "$HEADER_RE" "$SCAN_ROOT" \
            --exclude-dir=.git --exclude-dir=worktrees --exclude-dir=node_modules \
            --exclude-dir=DerivedData --exclude-dir=build --exclude-dir=.build 2>/dev/null | sort)

echo
if [ "$found" -eq 0 ]; then
  echo "NO PORTED ARTIFACTS found under $SCAN_ROOT."
  echo "Nothing was examined, so nothing was verified. After the first port lands,"
  echo "this means a Ported header has been lost."
  exit 3
fi

echo "examined $found ported artifact(s): $in_step in step, $adapted adapted, $diverged diverged, $drifted drifted, $sibling_absent not on this machine, $cannot_measure unmeasurable"
[ "$drifted" -gt 0 ] && exit 1
# 4 BEFORE 2: a fault on this machine cannot be softened by a question nothing
# here could ever have answered.
[ "$cannot_measure" -gt 0 ] && exit 4
[ "$sibling_absent" -gt 0 ] && exit 2
exit 0
