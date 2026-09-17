#!/bin/bash
# Point this clone's git at the hooks committed in the tree.
#
# backstage#1.
#
# WRITTEN IN ITS RELATIVE FORM, and an absolute one is UPGRADED rather than left
# alone. core.hooksPath is per clone, and an absolute path into one checkout makes
# every worktree of this repository run that checkout's hook against that
# checkout's tree (L398, ovation#138). The relative form resolves against the tree
# the push comes from, which is the tree that should be judged.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

WANTED="scripts/git-hooks"
CURRENT="$(git config --get core.hooksPath 2>/dev/null || true)"

if [ "$CURRENT" = "$WANTED" ]; then
    echo "hooks already installed: core.hooksPath = $WANTED"
    exit 0
fi

case "$CURRENT" in
    "") ;;
    /*) echo "upgrading an ABSOLUTE core.hooksPath to its relative form, so worktrees judge their own tree" ;;
    *)  echo "replacing core.hooksPath ($CURRENT)" ;;
esac

git config core.hooksPath "$WANTED" || { echo "REFUSED: could not set core.hooksPath"; exit 1; }
chmod +x "$WANTED"/* 2>/dev/null || true
echo "hooks installed: core.hooksPath = $WANTED"
