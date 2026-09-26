#!/bin/bash
# Ported-From: danwright32/ovation scripts/check-ci-workflow.sh @ 6814737f16c67e4f2a3fb5d062cb96d5dde6d44f
# Ported-Adapted: f61a9c062a5cfaf03877d365e65de514435416bc866b8125c8f588f5f62671d8
#
# Re-ported on 2026-09-26 by backstage#69, first ported by backstage#7. Three of
# its four rules are general and arrive unchanged: a timeout on every job, every
# action pinned to a sha, and one run per commit. What differs, all deliberate:
#
#   the documented command   re-derived, because the command this repository
#                            runs in CI is not the one the origin runs (L501);
#                            the reason sits beside WANTED below
#   the seams                BACKSTAGE_WORKFLOW_DIR, not OVATION_WORKFLOW_DIR,
#                            since a variable named for another product would
#                            be read by nothing here
#   the issue it names       backstage#7 where the origin names ovation#143, in
#                            the refusal for a missing workflow, because that
#                            is where this repository decided to have CI
# The CI workflow carries decisions, and a workflow file is the kind of thing
# nothing else in a repository ever reads.
#
# ovation#143. scripts/build-products.sh was written for CI, on Dan's decision of
# 2026-09-06 that CI BUILDS BOTH configurations, because skipping the build
# dependent suites there would leave the shipping build's bundle assertions
# running on exactly one machine, and those are the assertions that caught a real
# security defect in ovation#9. Then no CI existed: .github/workflows/ was
# absent, `gh run list` returned nothing, and no workflow had ever run.
#
# THREE THINGS, EACH BECAUSE IT FAILS SILENTLY:
#
#   a timeout on every job   GitHub's default is six hours. A hung job is worse
#                            than a failed one because it cannot be told from a
#                            slow one, and it holds a runner slot for all of it
#                            (L110, L313).
#   every action pinned      `@v4` is a moving tag, which is somebody else's code
#                            running here tomorrow, chosen by them (L25).
#   the documented command   the decision above is a sentence in a header until
#                            something reads it (L407).
#   one run per commit       a workflow on pull requests AND on push to other
#                            branches runs every pull request commit twice, and
#                            nothing fails: it only queues and bills (ovation#304).
#
# It prints paths, job names and counts. There is nothing here to redact.
set -uo pipefail
# ovation#399: every library is loaded through require_lib, which refuses by name
# rather than carrying on without it. See scripts/lib/require.sh.
. "$(dirname "${BASH_SOURCE[0]}")/lib/require.sh" 2>/dev/null || { echo "REFUSED: scripts/lib/require.sh is missing, so nothing was checked." >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${BACKSTAGE_WORKFLOW_DIR:-$REPO_ROOT/.github/workflows}"
# The command Dan decided on, kept as one string so the message can quote the
# thing it is asking for rather than describing it (L399).
# RE-DERIVED, not inherited (L501). backstage has no build step, and its suite
# does NOT scan the real tree: scripts/test-secrets-guard.sh exercises the guard
# against throwaway trees only, so a CI job running the suite alone would never
# look at the repository it is guarding. The guard runs FIRST because it is the
# faster of the two and the one whose failure matters most here.
WANTED="bash scripts/check-secrets.sh . && bash scripts/run-tests.sh"

if [ ! -d "$DIR" ]; then
  echo "REFUSED: there is no workflow directory at $DIR."
  echo "    This repository decided to have CI (backstage#7), so its absence is a"
  echo "    fault rather than a question nothing here can answer."
  exit 1
fi

FILES=""
for f in "$DIR"/*.yml "$DIR"/*.yaml; do
  [ -f "$f" ] || continue
  FILES="${FILES}${f}
"
done
FILE_COUNT="$(printf '%s' "$FILES" | grep -c . || true)"

if [ "$FILE_COUNT" -eq 0 ]; then
  echo "REFUSED: $DIR holds no workflow file."
  echo "    A directory that exists and is empty is not CI, and a check that"
  echo "    passed over zero files would be indistinguishable from one that"
  echo "    examined a healthy workflow."
  exit 1
fi

problems=0
job_count=0
saw_wanted_command=0

# ONE COMMIT, ONE RUN (ovation#304).
#
# ci.yml ran on a push to every branch AND on pull_request, with its concurrency
# group keyed on github.ref, which is the branch for one event and the pull
# request's merge ref for the other. Neither run cancelled the other, so every
# commit on a branch with an open pull request built both configurations twice,
# and on 2026-09-14 a pull request's jobs sat queued over 25 minutes behind the
# duplicates. After ovation#15 each duplicate bills macOS minutes.
#
# THE RULE IS WRITTEN AS THE REASON (L362): a workflow that runs on pull requests
# may also run on push only to main, the one branch no pull request is opened
# from. A push with no branch filter is every branch. It is asked of every
# workflow file rather than of ci.yml by name, because a workflow copied from
# this one doubles the same way (L30).
#
# LINE SHAPED, like everything above: the top level `on:` block, comment lines
# dropped, in the block form this repository writes and the one line list form.
# A spelling it does not recognise can only be refused too often, never waved
# through, except a push filter it cannot read at all, which is why an
# unfiltered push counts as every branch.
runs_twice_per_pull_request_commit() {
  local line rest item in_on=0 in_push=0 in_branches=0
  local has_pr=0 has_push=0 push_filtered=0 push_elsewhere=0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [ -n "${line//[[:space:]]/}" ] || continue
    if [ "$in_on" -eq 0 ]; then
      case "$line" in
        "on:"*)
          in_on=1
          rest="${line#on:}"
          case "$rest" in *pull_request*) has_pr=1 ;; esac
          case "$rest" in *push*) has_push=1 ;; esac
          ;;
      esac
      continue
    fi
    # The next top level key ends the block.
    [[ "$line" =~ ^[^[:space:]] ]] && break
    # An event: a key at two spaces.
    if [[ "$line" =~ ^\ \ [a-z_]+: ]]; then
      in_push=0
      in_branches=0
      case "$line" in
        "  pull_request:"*|"  pull_request_target:"*) has_pr=1 ;;
        "  push:"*) has_push=1; in_push=1 ;;
      esac
      continue
    fi
    [ "$in_push" -eq 1 ] || continue
    if [[ "$line" =~ ^\ \ \ \ branches: ]]; then
      push_filtered=1
      rest="${line#*branches:}"
      if [[ "$rest" == *"["* ]]; then
        rest="${rest//[\[\]\'\"]/}"
        for item in ${rest//,/ }; do
          [ "$item" = "main" ] || push_elsewhere=1
        done
      else
        in_branches=1
      fi
    elif [[ "$line" =~ ^\ \ \ \ [a-z_-]+: ]]; then
      in_branches=0
    elif [ "$in_branches" -eq 1 ]; then
      item="${line#*- }"
      item="${item//[\'\"[:space:]]/}"
      [ "$item" = "main" ] || push_elsewhere=1
    fi
  done < "$1"
  [ "$has_pr" -eq 1 ] && [ "$has_push" -eq 1 ] \
    && { [ "$push_filtered" -eq 0 ] || [ "$push_elsewhere" -eq 1 ]; }
}

while IFS= read -r file; do
  [ -n "$file" ] || continue

  # Jobs are the two space keys under `jobs:`. Nothing here parses YAML properly,
  # and it does not need to: the shapes it asks about are line shaped, and a
  # dependency on a YAML parser would be a tool this repository does not have on
  # every machine that has to run this.
  # WHAT A JOB MUST CARRY, judged in one place for the end of a job and the end of
  # the file alike, so the two exits cannot come to ask different things.
  #
  # A MAC JOB SELECTS THE PINNED XCODE (ovation#270). Both Mac jobs built with the
  # image's default Xcode and nothing named a version, so an image update could
  # move the compiler with no change here and the push gate on Dan's Mac would
  # stop predicting CI. A third Mac job added tomorrow would quietly do the same,
  # which is why this is a rule over every job rather than a line in two.
  finish_job() {
    [ -n "$current_job" ] || return 0
    if [ "$job_has_timeout" -eq 0 ]; then
      echo "NO TIMEOUT: $current_job in $(basename "$file")"
      problems=$((problems+1))
    fi
    if [ "$job_is_mac" -eq 1 ] && [ "$job_selects_xcode" -eq 0 ]; then
      echo "NO PINNED XCODE: $current_job in $(basename "$file")"
      echo "    runs on macOS without running scripts/select-xcode.sh, so it builds"
      echo "    with whatever Xcode the image ships as its default (ovation#270)."
      problems=$((problems+1))
    fi
  }

  in_jobs=0
  current_job=""
  job_has_timeout=0
  job_is_mac=0
  job_selects_xcode=0
  while IFS= read -r line; do
    case "$line" in
      "jobs:"*) in_jobs=1; continue ;;
    esac
    [ "$in_jobs" -eq 1 ] || continue
    # A COMMENT LINE SAYS NOTHING A JOB DOES. The same rule lib/workflow-text.sh
    # applies to the file as a whole (ovation#221): a step commented out is not a
    # step, and a sentence naming the selector is not a selection (L135).
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    # A two space indented key that is not deeper: a job name.
    if grep -qE '^  [A-Za-z0-9_-]+:[[:space:]]*$' <<< "$line"; then
      finish_job
      current_job="$(printf '%s' "$line" | tr -d ' :')"
      job_count=$((job_count+1))
      job_has_timeout=0
      job_is_mac=0
      job_selects_xcode=0
      continue
    fi
    case "$line" in
      *timeout-minutes:*) job_has_timeout=1 ;;
    esac
    case "$line" in
      *runs-on:*macos*) job_is_mac=1 ;;
    esac
    case "$line" in
      *"bash scripts/select-xcode.sh"*) job_selects_xcode=1 ;;
    esac
  done < "$file"
  finish_job

  # Every `uses:` must name a 40 character commit, not a tag or a branch.
  while IFS= read -r used; do
    [ -n "$used" ] || continue
    case "$used" in
      *@*) ;;
      *) echo "UNPINNED: $used in $(basename "$file") names no version at all"
         problems=$((problems+1)); continue ;;
    esac
    ref="${used##*@}"
    if ! grep -qE '^[0-9a-f]{40}$' <<< "$ref"; then
      echo "UNPINNED: $used in $(basename "$file")"
      echo "    a tag or branch is somebody else's choice of what runs here"
      echo "    tomorrow. Pin the commit: gh api repos/<owner>/<repo>/git/ref/tags/<tag>"
      problems=$((problems+1))
    fi
  done < <(grep -oE 'uses:[[:space:]]*[^[:space:]]+' "$file" | sed 's/uses:[[:space:]]*//')

  if runs_twice_per_pull_request_commit "$file"; then
    echo "RUNS TWICE PER PULL REQUEST COMMIT: $(basename "$file")"
    echo "    it runs on pull requests and on push to branches other than main, so"
    echo "    every commit on a branch with an open pull request runs it twice, and"
    echo "    neither run cancels the other (ovation#304). Run on push to main only."
    problems=$((problems+1))
  fi

  if grep -qF "$WANTED" "$file"; then
    saw_wanted_command=1
  fi
done <<< "$FILES"

if [ "$saw_wanted_command" -eq 0 ]; then
  echo "MISSING THE DOCUMENTED COMMAND: no workflow runs"
  echo "    $WANTED"
  echo "    Dan decided on 2026-09-06 that CI builds BOTH configurations, because"
  echo "    the alternative leaves the shipping build's bundle assertions running"
  echo "    on one machine. A workflow that only runs the suite has quietly taken"
  echo "    the option that decision rejected, and it goes green while doing it."
  problems=$((problems+1))
fi

# ---------------------------------------------------------------------------
# EVERY CHECK A WORKFLOW RUNS IS DECLARED AS ONE SOMETHING RUNS (ovation#214).
#
# scripts/lib/script-roles.tsv says, for every script here, what watches it, and
# scripts/test-preconditions.sh already held ONE direction of that: every script
# declared `workflow` is named by a workflow file. Nothing held the reverse, so
# six scripts run by .github/workflows/ci.yml were declared `tool`, which that
# file defines as "Run by a person on demand". Each carried a reason that was
# true when it was written and had since been answered by gate_check's three
# outcomes (ovation#135), so every entry read as a considered decision while
# describing a state that had changed (L346).
#
# A COMPARISON IN ONE DIRECTION FINDS ONLY WHAT SOMEBODY REMEMBERED TO DECLARE,
# which was never the half that went wrong. Both sides are enumerated from their
# own source and held against each other (L582, L41).
#
# THE ROLES IT ACCEPTS ARE WRITTEN AS THE REASON FOR ACCEPTING THEM (L362): the
# role must name something AUTOMATIC as what runs the check. `workflow` says a
# workflow does and `gated` says the push gate or the preconditions entry point
# does, and the partition test holds a `gated` entry to actually being named by
# one of them, so neither can be claimed to dodge this. Every other role,
# including one nobody has invented yet, refuses: an allow list fails closed and
# a refuse list is silent about whatever it does not mention (L96).
require_lib "$REPO_ROOT/scripts/lib/script-roles.sh"

# READ FROM STEPS, NOT FROM THE WHOLE FILE. Both workflow files here explain
# themselves at length and name scripts while doing it, and a rule reading every
# line would refuse on a sentence ABOUT a check rather than on a step that runs
# one (L135). What counts as a step's text is decided once, in
# lib/workflow-text.sh, because scripts/test-preconditions.sh asks the reverse
# question of the same files and two readers drift (ovation#221, L370).
require_lib "$REPO_ROOT/scripts/lib/workflow-text.sh"
NAMED_CHECKS="$(workflow_step_text "$DIR" | grep -oE 'check-[a-z0-9-]+\.(sh|py)' | sort -u)"
NAMED_COUNT="$(printf '%s' "$NAMED_CHECKS" | grep -c . || true)"

if [ "$NAMED_COUNT" -gt 0 ] && [ ! -f "$SCRIPT_ROLES_TSV" ]; then
  # ONE SIDE OF A COMPARISON MISSING IS NOT AGREEMENT (L345, L98).
  echo "NO INVENTORY TO COMPARE AGAINST: $SCRIPT_ROLES_TSV is not there."
  echo "    $NAMED_COUNT check script(s) are run by a workflow and nothing here can"
  echo "    say whether the inventory agrees about what runs them. A comparison"
  echo "    that could not read one of its two sides is not a pass."
  problems=$((problems+1))
elif [ "$NAMED_COUNT" -gt 0 ]; then
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    role="$(role_of "$name")"
    case "$role" in
      workflow|gated) ;;
      "")
        echo "NO INVENTORY ENTRY: $name is run by a workflow and scripts/lib/script-roles.tsv"
        echo "    declares nothing about it, so nothing can say what watches it."
        echo "    Declare it there, with the reason, beside every other script."
        problems=$((problems+1))
        ;;
      *)
        echo "RUN BY A WORKFLOW, DECLARED AS SOMETHING ELSE: $name is declared '$role'"
        echo "    A workflow file runs it. Only 'workflow' and 'gated' say something"
        echo "    automatic does; 'tool' says a person does, on demand, which is a"
        echo "    different fact and leaves the check looking unwatched."
        problems=$((problems+1))
        ;;
    esac
  done <<< "$NAMED_CHECKS"
fi

# DOES IT PARSE AT ALL (ovation#155). Everything above reads lines, which is the
# right shape for the questions it asks and is blind to the one failure that
# costs the most: a workflow file GitHub cannot parse runs no jobs, reports a
# failure with no log, and looks from `gh run list` exactly like a job that ran
# and failed. That is how the liveness workflow shipped broken: an unindented
# line inside a `run: |` block ended the block scalar.
#
# THE PARSER IS WHATEVER THIS MACHINE HAS. Ruby ships with macOS and with every
# ubuntu runner; python's yaml module is not in the standard library and is only
# used if it is there. A machine with NEITHER answers CANNOT MEASURE rather than
# passing, because a check that examined nothing must never read as one that
# found nothing wrong (L98).
parse_with_ruby() { ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$1" 2>&1; }
parse_with_python() { python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$1" 2>&1; }

PARSER=""
if command -v ruby >/dev/null 2>&1 && ruby -ryaml -e 'exit 0' >/dev/null 2>&1; then
  PARSER="ruby"
elif python3 -c 'import yaml' >/dev/null 2>&1; then
  PARSER="python"
fi

if [ -z "$PARSER" ]; then
  echo "CANNOT MEASURE: no YAML parser on this machine, so whether the workflow"
  echo "    files PARSE was not checked. Everything else above was."
  echo "    A workflow GitHub cannot parse runs no jobs and reports a failure with"
  echo "    no log, which is the one failure the line checks above cannot see."
  [ "$problems" -eq 0 ] || exit 1
  exit 2
fi

while IFS= read -r file; do
  [ -n "$file" ] || continue
  case "$PARSER" in
    ruby) error="$(parse_with_ruby "$file")" ;;
    python) error="$(parse_with_python "$file")" ;;
  esac
  if [ -n "$error" ]; then
    echo "DOES NOT PARSE: $(basename "$file")"
    printf '%s\n' "$error" | sed 's/^/    /' | head -5
    echo "    A workflow file GitHub cannot parse runs NO jobs at all, and reports"
    echo "    a failure with no log to read."
    problems=$((problems+1))
  fi
done <<< "$FILES"

echo "examined $FILE_COUNT workflow file(s) and $job_count job(s) under $DIR"
echo "    $NAMED_COUNT check script(s) named by a step, held against the inventory"
echo "    parsed with: $PARSER"
[ "$problems" -eq 0 ] || exit 1
exit 0
