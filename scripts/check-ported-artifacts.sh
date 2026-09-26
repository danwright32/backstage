#!/bin/bash
# Ported-From: danwright32/ovation scripts/check-ported-artifacts.sh @ 6814737f16c67e4f2a3fb5d062cb96d5dde6d44f
# Ported-Adapted: 0dd764723d29a43b0e69569fa81d21a63ebb13646d9ccd35f53b24059d8cbec1
#
# Re-ported on 2026-09-26 by backstage#69, first ported by backstage#2. Do not
# edit this copy to fix a fault that is also in the origin: fix it there and
# re-port, or the two silently diverge and the shared definition stops being
# shared (L263). Every constant was re-checked against what backstage needs
# rather than inherited (L501).
#
# THE ONE DELIBERATE DIFFERENCE: the seams are BACKSTAGE_PORT_SCAN_ROOT and
# BACKSTAGE_SIBLING_SEARCH_ROOTS, not their OVATION_ names, since an environment
# variable named for another product would be read by nothing here. That covers
# the variable, the seam list in the header below, and the refusal that names it.
# Assert that every file Ovation ported from a sibling repository records where
# it came from, and that the commit it names is still on that sibling's main.
#
# Implementation plan 0.4.6. Ovation ports at least eleven files one line at a
# time from Downbeat and Overture. A clone copies the pattern AS FIRST WRITTEN,
# including every value already corrected in the original, and the clone's own
# note that it follows a proven pattern is what makes it read as safe (L501). A
# port made from a stale checkout or an unmerged branch is therefore reported
# here rather than assumed.
#
# Every ported file carries, at the START of a comment line, in its own comment
# syntax ('#' for shell, yaml and gitignore, '//' for Swift):
#
#      <comment opener><space>Ported<dash>From: <owner>/<repo> <path> @ <commit>
#
# The marker is written with <dash> there on purpose. THIS SCRIPT HAS TO NAME ITS
# OWN NEEDLE IN ORDER TO SEARCH FOR IT, so an unescaped example here would make
# the check match itself, its own test, and every document describing the
# convention (L245). Measured on the first real run: seven bogus artifacts, all
# of them this file and its test.
#
# The remedy is the RULE, not a list of exempt filenames (L362). A real header
# sits at the start of its comment; prose about one is indented inside a block.
# So the match is anchored to allow at most one space after the comment opener,
# which no explanatory paragraph satisfies.
#
# Outcomes, one per artifact, each with its own wording because distinct causes
# need distinct messages (L11):
#
#     OK                  the commit is an ancestor of that sibling's main
#     NOT ON MAIN         the sibling was found, the commit is not on its main
#     COMMIT NOT FOUND    the sibling was found, the commit is not in it at all
#     CANNOT MEASURE      the sibling repository is not on this machine
#     UNREADABLE HEADER   a Ported-From line that cannot be parsed
#
# Exit codes, so a caller can tell them apart without parsing text:
#
#     0  every artifact verified, and there was at least one
#     1  at least one NOT ON MAIN
#     2  at least one CANNOT MEASURE or COMMIT NOT FOUND
#     3  no ported artifacts found at all
#     4  at least one UNREADABLE HEADER
#
# NOTHING FOUND IS NOT A PASS. Ovation has zero ported files on the day this is
# written, and a check that exits 0 on an empty tree would report success for
# months and be believed by the time it mattered (L98, L182). CANNOT MEASURE is
# not a pass either, for the same reason: a checker that goes green because it
# could not find what it was meant to check is indistinguishable from one that
# checked everything.
#
# Seams, so the test suite never reads a real sibling repository (L2):
#     BACKSTAGE_PORT_SCAN_ROOT         where to look for ported files
#     BACKSTAGE_SIBLING_SEARCH_ROOTS   colon separated roots to resolve siblings in
set -uo pipefail
# ovation#399: every library is loaded through require_lib, which refuses by name
# rather than carrying on without it. See scripts/lib/require.sh.
. "$(dirname "${BASH_SOURCE[0]}")/lib/require.sh" 2>/dev/null || { echo "REFUSED: scripts/lib/require.sh is missing, so nothing was checked." >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN_ROOT="${BACKSTAGE_PORT_SCAN_ROOT:-$REPO_ROOT}"
# shellcheck source=lib/repo-git.sh
require_lib "$(dirname "${BASH_SOURCE[0]}")/lib/repo-git.sh"

# THE SIBLINGS ARE LOOKED FOR BESIDE OVATION'S PRIMARY CHECKOUT (ovation#314), as
# the library works that out, and nowhere else. This used to be folder names
# typed under the home directory. One had already gone dead when Overture moved,
# and it cost nothing while it stood, which is exactly why an entry in a list like
# that survives unnoticed; none of them said anything about where Ovation itself
# is (L153).
if ! SEARCH_ROOTS="$(sibling_search_roots "$REPO_ROOT")"; then
    echo "CANNOT MEASURE: where the sibling checkouts live could not be worked out (see above)."
    echo "    Set BACKSTAGE_SIBLING_SEARCH_ROOTS to the folder holding them."
    exit 2
fi

# Assembled from pieces so this file contains no literal instance of the marker
# it looks for. One definition, used by both the file search and the line
# extraction, so the two can never drift into looking for different things (L70).
MARKER="Ported""-From:"
HEADER_RE="^[[:space:]]*(#|//)[[:space:]]?${MARKER}"

if [ ! -d "$SCAN_ROOT" ]; then
    echo "CANNOT MEASURE: the scan root does not exist: $SCAN_ROOT"
    exit 2
fi

# EVERY QUESTION TO A SIBLING GOES THROUGH `clean_git` FROM THE LIBRARY. An
# inherited GIT_DIR beats `git -C`, and git exports GIT_DIR to its hooks. From the
# primary checkout that survived by luck, because a relative `.git` beside
# `-C /path/to/sibling` resolves to the sibling's own; from a worktree it is
# absolute, every sibling answered with Ovation's own origin, and a push was
# refused for nine unmeasurable ports on 2026-09-08 with all nine present (L70,
# L621).

# Which checkout a sibling is comes from the library's resolve_sibling (ovation#417).

# THE REFS THAT MEAN MAIN, every one the sibling has, REMOTE TRACKING FIRST
# (ovation#401). A checkout another session works in stands on a feature branch,
# and its local main is not moved by pulls to that branch, so it lags. A port taken
# from the real main was refused as "a branch that never merged", the opposite of
# what happened. A local copy is named after what it mirrors (L454), so the remote
# tracking main is asked first and the local one second, and whichever answers is
# named. Nothing here fetches or moves either: that checkout is another session's.
# Refused rather than guessed if the sibling has neither.
main_refs() {
    local repo="$1" ref found=""
    for ref in origin/main main; do
        if clean_git -C "$repo" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
            found="${found}${ref} "
        fi
    done
    [ -n "$found" ] || return 1
    printf '%s\n' "${found% }"
}

found=0
not_on_main=0
# TWO KINDS OF CANNOT MEASURE (ovation#135). A sibling that is not on this
# machine is a question nothing here could ever have answered, and every fresh
# clone, second machine and CI runner is in that state. A sibling that IS here
# and cannot answer is a fault on this machine. The gate lets the first through
# while naming it and refuses the second, which it cannot do while they share one
# code (L11, L260).
sibling_absent=0
cannot_measure=0
unreadable=0

# Nested checkouts hold a full second copy of a repository's sources, and a
# recursive walk collects them (L234). Overture's .claude/worktrees proves they
# exist in this estate.
while IFS= read -r file; do
    while IFS= read -r line; do
        found=$((found+1))
        spec="${line#*$MARKER}"
        # shellcheck disable=SC2086
        set -- $spec
        slug="${1:-}"; path="${2:-}"; at="${3:-}"; commit="${4:-}"
        rel="${file#$SCAN_ROOT/}"
        if [ "$#" -ne 4 ] || [ "$at" != "@" ] || [ -z "$slug" ] || [ -z "$path" ] \
           || ! grep -q '^[^/][^/]*/[^/][^/]*$' <<< "$slug" \
           || ! grep -qi '^[0-9a-f]\{7,40\}$' <<< "$commit"; then
            echo "UNREADABLE HEADER: $rel"
            echo "    could not read a repository, path and commit out of: ${spec# }"
            unreadable=$((unreadable+1))
            continue
        fi
        if ! sibling="$(resolve_sibling "$slug" "$SEARCH_ROOTS")"; then
            echo "CANNOT MEASURE: $rel"
            echo "    the sibling repository $slug is not on this machine"
            echo "    roots searched: $SEARCH_ROOTS"
            sibling_absent=$((sibling_absent+1))
            continue
        fi
        if ! refs="$(main_refs "$sibling")"; then
            echo "CANNOT MEASURE: $rel"
            echo "    $slug has neither a main nor an origin/main to compare against"
            cannot_measure=$((cannot_measure+1))
            continue
        fi
        if ! clean_git -C "$sibling" cat-file -e "${commit}^{commit}" 2>/dev/null; then
            echo "COMMIT NOT FOUND: $rel"
            echo "    $slug does not contain $commit, so the port cannot be placed"
            cannot_measure=$((cannot_measure+1))
            continue
        fi
        answered=""
        for ref in $refs; do
            if clean_git -C "$sibling" merge-base --is-ancestor "$commit" "$ref" 2>/dev/null; then
                answered="$ref"; break
            fi
        done
        if [ -n "$answered" ]; then
            echo "OK: $rel  ($slug $path @ ${commit:0:8}, on $answered)"
        else
            echo "NOT ON MAIN: $rel"
            echo "    $slug $path @ ${commit:0:8} is not an ancestor of ${refs// / or }"
            echo "    it was ported from a branch or a checkout that never merged"
            not_on_main=$((not_on_main+1))
        fi
    done < <(grep -hE "$HEADER_RE" "$file" 2>/dev/null)
done < <(grep -rlE "$HEADER_RE" "$SCAN_ROOT" \
            --exclude-dir=.git --exclude-dir=worktrees --exclude-dir=node_modules \
            --exclude-dir=DerivedData --exclude-dir=build 2>/dev/null | sort)

echo
if [ "$found" -eq 0 ]; then
    echo "NO PORTED ARTIFACTS found under $SCAN_ROOT."
    echo "Nothing was examined, so nothing was verified. This is the expected"
    echo "answer only until the first port lands; after that it means a"
    echo "Ported-From header has been lost."
    exit 3
fi

echo "examined $found ported artifact(s): $((found - not_on_main - cannot_measure - unreadable - sibling_absent)) ok, $not_on_main not on main, $sibling_absent not on this machine, $cannot_measure unmeasurable, $unreadable unreadable"
[ "$not_on_main" -gt 0 ] && exit 1
# 4 BEFORE 2: a run that must be refused cannot be softened by an unrelated
# question nothing on this machine could have answered.
[ "$unreadable" -gt 0 ] && exit 4
[ "$cannot_measure" -gt 0 ] && exit 4
[ "$sibling_absent" -gt 0 ] && exit 2
exit 0
