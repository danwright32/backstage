#!/bin/bash
# Ported-From: danwright32/ovation scripts/lib/repo-git.sh @ 04e3dc90848ae267f4e55e2b58407f2de41dc43a
#
# Ported on 2026-09-17 by backstage#2. Do not edit this copy to fix a fault
# that is also in the origin: fix it there and re-port, or the two silently
# diverge and the shared definition stops being shared (L263). Every constant
# was re-checked against what backstage needs rather than inherited (L501).
# The seam names are the one deliberate difference, since an environment
# variable named for another product would be read by nothing here.
# Asking git about a repository, and finding the folder the sibling checkouts
# live in. ovation#314.
#
# Sourced, never run. `scripts/test-sibling-root.sh` covers both functions and
# holds the scan that refuses a hand rolled copy of either anywhere else.
#
# WHY ONE FILE. Three scripts each carried their own copy of `clean_git` under
# three names, and three found Downbeat and Overture three different ways: the
# parent of the running checkout, and two folder names typed under the home
# directory. The first was wrong in every worktree, which is where nearly every
# push is made from, so the plan claims check had been answering CANNOT MEASURE
# on those pushes and the gate let it through (L668, L98). The typed names were
# right only until something moved, and Overture's move had already blinded one
# of them once (L153). A shared definition is the component; the scan is the
# guard; neither is worth much without the other (L613).

# ASKING A REPOSITORY ABOUT ITSELF NEEDS MORE THAN `git -C`. An inherited GIT_DIR
# BEATS the -C, so every question would be answered by whatever GIT_DIR names.
# Git EXPORTS GIT_DIR to its hooks and the whole suite runs inside the pre-push
# hook, so this is the ordinary case rather than a hypothetical: on 2026-09-08 it
# made a push report nine siblings as absent while all nine sat on the disk, and
# made the install record describe the pushing worktree instead of the fixture it
# was handed.
clean_git() {
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
        -u GIT_COMMON_DIR -u GIT_NAMESPACE git "$@"
}

# The folder holding the PRIMARY checkout of the repository <dir> belongs to,
# which is where Downbeat and Overture sit beside Ovation.
#
#     sibling_root <dir>      prints the folder, or refuses with a reason on stderr
#
# IT IS ASKED OF GIT, NOT OF THE PATH. A worktree's own top level is somewhere
# inside the primary checkout, so any answer built from where the running copy
# sits is wrong from a worktree. Git's COMMON directory is the primary checkout's
# `.git` from every worktree of it, so the folder above that checkout is the same
# answer from all of them.
#
# IT REFUSES RATHER THAN GUESSES. A copy of Ovation that is not a git checkout,
# or one whose git folder is not inside a checkout, has no primary checkout to
# stand beside, and a guessed folder would send every caller to look somewhere
# arbitrary and report the siblings missing (L75, L11).
sibling_root() {
    local from="$1" common
    if ! common="$(clean_git -C "$from" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
       || [ -z "$common" ]; then
        echo "sibling_root: $from is not inside a git repository, so where the sibling checkouts live cannot be worked out" >&2
        return 1
    fi
    case "$common" in
        */.git) ;;
        *)
            echo "sibling_root: the git folder for $from is $common, which is not inside a checkout, so there is no primary checkout for the siblings to sit beside" >&2
            return 1
            ;;
    esac
    dirname "$(dirname "$common")"
}
