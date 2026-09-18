#!/bin/bash
# Ported-From: danwright32/ovation scripts/lib/workflow-text.sh @ 7fd505d433dbbbc4161029d3343da7d1a9604d7b
#
# Ported on 2026-09-17 by backstage#7, because check-ci-workflow.sh sources it
# and exited 0 without it, reporting success while two of its parts could not
# load at all. Seam names are the one deliberate difference (L501).
# The one reader of what a GitHub workflow file RUNS, as opposed to what it says.
# ovation#221.
#
# TWO RULES ASK WHAT A WORKFLOW NAMES, one in each direction:
#
#   scripts/check-ci-workflow.sh     every check a workflow runs is declared as
#                                    one something automatic runs (ovation#214)
#   scripts/test-preconditions.sh    every script declared `workflow` is named by
#                                    a workflow file (ovation#155)
#
# The first stopped reading comments when it was written; the second went on
# grepping whole files. Both workflow files here explain themselves at length and
# name scripts while doing it, so a check could be declared as run by CI, be
# mentioned only in a sentence explaining why it is NOT run there, and be run by
# nothing at all, while both sides of the comparison read as correct. A guard
# matching source text over a whole file is satisfied by any occurrence (L135),
# and two greps that each decide what "named" means are two rules that drift
# (L370). So both read through here.
#
# WHAT IS DROPPED IS WHOLE COMMENT LINES, AND NOTHING ELSE. A `run: |` block puts
# its commands on the lines that follow, so narrowing to lines carrying `run:`
# would stop seeing most of what a workflow runs. A trailing `# ...` after a
# command is NOT stripped, because a `#` inside a shell command (`${#x}`, a quoted
# string) is not a comment, and a reader that guessed would drop real commands.
# The cost is that a script named only in a trailing comment still counts; no
# workflow here writes one, and that is the limit said out loud.
#
# Sourced, never run.

# workflow_step_text <workflow dir>
#
# Every non comment line of every workflow file in the directory, in the same
# order the files glob in. The same two extensions GitHub reads.
workflow_step_text() {
    local dir="$1" file
    for file in "$dir"/*.yml "$dir"/*.yaml; do
        [ -f "$file" ] || continue
        grep -v '^[[:space:]]*#' "$file"
    done
}

# workflow_names_script <script file name> <workflow dir>
#
# Succeeds when some step of some workflow in the directory names the script.
# A fixed string, never a pattern: a dot in a script's name must not match any
# character (L104).
workflow_names_script() {
    workflow_step_text "$2" | grep -qF -- "$1"
}
