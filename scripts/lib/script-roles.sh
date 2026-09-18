#!/bin/bash
# Ported-From: danwright32/ovation scripts/lib/script-roles.sh @ 98b9cf9c8f6bf47d1db0e689de347e32d2d573ef
#
# Ported on 2026-09-17 by backstage#7, because check-ci-workflow.sh sources it
# and exited 0 without it, reporting success while two of its parts could not
# load at all. Seam names are the one deliberate difference (L501).
# The one reader of scripts/lib/script-roles.tsv. ovation#86.
#
# TWO COMPLETENESS RULES READ THIS, in test-preconditions.sh and in
# test-output-privacy.sh, and they read it THROUGH HERE rather than each parsing
# the file. Sharing the data while copying the code that applies it is not
# consolidation: the shared file reads as the single source of truth and nobody
# asks whether the parsing beside it was duplicated (L370).
#
# Sourced, never run.

# Where the inventory is, resolved from THIS file's own location rather than
# from the caller's working directory, because a path re-derived from a caller
# is relative to wherever that caller was invoked from (L372).
_SCRIPT_ROLES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# OVERRIDABLE, so a suite can plant an inventory and drive a disagreement rather
# than editing the one the repository runs on (ovation#214, L2). The default is
# the real file, so nothing that does not ask for the seam can reach a fixture.
SCRIPT_ROLES_TSV="${BACKSTAGE_SCRIPT_ROLES_TSV:-${_SCRIPT_ROLES_LIB_DIR}/script-roles.tsv}"
SCRIPTS_DIR="$(cd "${_SCRIPT_ROLES_LIB_DIR}/.." && pwd)"

# Every declared entry, as `path<TAB>role<TAB>reason`. Comments and blank lines
# are dropped; nothing else is.
roles_entries() {
    [ -f "$SCRIPT_ROLES_TSV" ] || return 1
    grep -v '^#' "$SCRIPT_ROLES_TSV" | grep -v '^[[:space:]]*$'
}

roles_paths() { roles_entries | cut -f1 | sort; }

role_of() { roles_entries | awk -F'\t' -v p="$1" '$1 == p { print $2; exit }'; }

reason_of() { roles_entries | awk -F'\t' -v p="$1" '$1 == p { print $3; exit }'; }

roles_with() { roles_entries | awk -F'\t' -v r="$1" '$2 == r { print $1 }' | sort; }

# Every script actually on disk, relative to scripts/, sorted.
#
# IT LOOKS FOR WHAT A SCRIPT IS, not for one extension. The rules this replaced
# matched `check-*.sh`, which is why `check-design-collisions.py` was invisible
# to both of them while being run by nothing at all.
scripts_on_disk() {
    ( cd "$SCRIPTS_DIR" && find . -type f \( -name '*.sh' -o -name '*.py' \) \
        -not -path './git-hooks/*' | sed 's|^\./||' | sort )
}
