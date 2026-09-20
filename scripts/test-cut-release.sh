#!/bin/bash
# The suite for scripts/cut-release.sh.
#
# backstage#12, ovation#423. A tag is what other repositories pin to, so the
# thing worth testing is not that it can tag, it is that it REFUSES. Every case
# below drives one refusal and reads the sentence it produced, because a check
# that fails for a reason it is not about is a check that passed by accident
# (L140, L11).
#
# THE API AND THE REMOTE ARE BOTH PLANTED. `BACKSTAGE_RELEASE_FAKE_DIR` holds one
# file per answer, so no case here reaches GitHub, resolves a real remote, or can
# create anything (L2). The real paths are exercised once, deliberately, by the
# dry run case at the end, because a seam that hides the real path from every
# test leaves the real path untested (L246).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. "$(dirname "$0")/lib/test-harness.sh"

TARGET="scripts/cut-release.sh"

harness_begin "cut release tests" 31
require_target "$TARGET"
harness_temp_dir WORK

# One planted world per case. `plant <dir> <file> <contents>` writes an answer.
plant() { mkdir -p "$1"; printf '%s' "$3" > "$1/$2"; }

GREEN_RUNS=$'Shell suites on macos-latest\tcompleted\tsuccess\nShell suites on ubuntu-latest\tcompleted\tsuccess\nSecrets in the history\tcompleted\tsuccess'
GREEN_WORKFLOWS=$'Shell suites on ${{ matrix.os }}\nSecrets in the history'
HEAD_LINE=$'0e71051627c6a43a6e7e7e08b3a997895cc969b5\trefs/heads/main'

world() {
    # THE NAME IS REQUIRED, and that guard is here rather than at each call site.
    # `rm -rf "$WORK/$1"` with an empty name is `rm -rf "$WORK/"`, which empties
    # the harness temp directory every other case is standing in. Every call below
    # passes a literal, so this can only fire on a future one, which is exactly
    # when nobody is looking (L5).
    if [ -z "${1:-}" ]; then
        printf 'world() was called with no name, which would empty the temp dir.\n' >&2
        exit 2
    fi
    local dir="$WORK/$1"; shift
    rm -rf "$dir"; mkdir -p "$dir"
    plant "$dir" ls-remote "$HEAD_LINE"
    plant "$dir" ls-remote-tags ""
    plant "$dir" check-runs "$GREEN_RUNS"
    plant "$dir" workflows "$GREEN_WORKFLOWS"
    plant "$dir" secrets-history "clean: read 143 of 143 committed blob(s), 0 not read, 0 findings."
    printf '%s' "$dir"
}

run_on() { BACKSTAGE_RELEASE_FAKE_DIR="$1" bash "$TARGET" "${@:2}" 2>&1; }
status_on() { BACKSTAGE_RELEASE_FAKE_DIR="$1" bash "$TARGET" "${@:2}" >/dev/null 2>&1; printf '%s' "$?"; }

# ---------------------------------------------------------------------------
# The shape of the version itself (backstage#12).
# ---------------------------------------------------------------------------
W="$(world shape)"
check "a 1.0.0 is refused while the public surface is open" "$(status_on "$W" 1.0.0 --dry-run)" "1"
check "and the refusal says WHY rather than just naming a pattern" \
    "$(run_on "$W" 1.0.0 --dry-run | grep -c 'mid decision')" "1"
check "a version that is not a version at all is refused" "$(status_on "$W" latest --dry-run)" "1"
check "and 0.1.0 is accepted by the shape rule" \
    "$(run_on "$W" 0.1.0 --dry-run | grep -c 'not a shape')" "0"

# ---------------------------------------------------------------------------
# A tag that already exists is never moved.
# ---------------------------------------------------------------------------
W="$(world exists)"
plant "$W" ls-remote-tags $'abc123\trefs/tags/0.1.0'
check "an existing tag is refused rather than moved" "$(status_on "$W" 0.1.0 --dry-run)" "1"
check "and the refusal says what moving one would do to consumers" \
    "$(run_on "$W" 0.1.0 --dry-run | grep -c 'pinned consumer')" "1"

# ---------------------------------------------------------------------------
# THE CASE THE ISSUE ASKS FOR: checks that are not all concluded green, NAMED.
# ---------------------------------------------------------------------------
W="$(world failing)"
plant "$W" check-runs $'Shell suites on macos-latest\tcompleted\tsuccess\nShell suites on ubuntu-latest\tcompleted\tfailure\nSecrets in the history\tcompleted\tsuccess'
check "a failed check refuses the release" "$(status_on "$W" 0.1.0 --dry-run)" "1"
check "and it NAMES the check that failed, rather than failing generically" \
    "$(run_on "$W" 0.1.0 --dry-run | grep -c 'failure: Shell suites on ubuntu-latest')" "1"
check "and does not name the ones that passed as though they were the problem" \
    "$(run_on "$W" 0.1.0 --dry-run | grep -c 'failure: Secrets in the history')" "0"

W="$(world running)"
plant "$W" check-runs $'Shell suites on macos-latest\tcompleted\tsuccess\nShell suites on ubuntu-latest\tin_progress\t\nSecrets in the history\tcompleted\tsuccess'
check "a check still running refuses the release" "$(status_on "$W" 0.1.0 --dry-run)" "1"
check "and says it is still running rather than calling it a failure" \
    "$(run_on "$W" 0.1.0 --dry-run | grep -c 'still running: Shell suites on ubuntu-latest')" "1"

# ---------------------------------------------------------------------------
# Nothing to read is a refusal, not a pass (L98).
# ---------------------------------------------------------------------------
W="$(world nochecks)"
plant "$W" check-runs ""
check "a commit with NO check runs is refused" "$(status_on "$W" 0.1.0 --dry-run)" "1"
check "and says nothing judged it, rather than reporting it green" \
    "$(run_on "$W" 0.1.0 --dry-run | grep -c 'nothing has judged it')" "1"

W="$(world noworkflows)"
plant "$W" workflows ""
check "a commit whose workflows cannot be read is refused" "$(status_on "$W" 0.1.0 --dry-run)" "1"
check "and says a green list of nothing is not evidence" \
    "$(run_on "$W" 0.1.0 --dry-run | grep -c 'not evidence')" "1"

# ---------------------------------------------------------------------------
# A workflow that exists at the commit but never ran at it.
# ---------------------------------------------------------------------------
W="$(world neverran)"
plant "$W" workflows $'Shell suites on ${{ matrix.os }}\nSecrets in the history\nThe scopes proof'
check "a declared workflow with no run at that commit refuses" "$(status_on "$W" 0.1.0 --dry-run)" "1"
check "and NAMES the one that never ran" \
    "$(run_on "$W" 0.1.0 --dry-run | grep -c 'declared, never ran: The scopes proof')" "1"
check "and does not accuse the two that did run" \
    "$(run_on "$W" 0.1.0 --dry-run | grep -c 'declared, never ran: Secrets in the history')" "0"

# ---------------------------------------------------------------------------
# The remote is the source of the target, never a local ref (L454).
# ---------------------------------------------------------------------------
W="$(world noremote)"
plant "$W" ls-remote ""
check "a remote that does not name main refuses rather than guessing" "$(status_on "$W" 0.1.0 --dry-run)" "1"
check "and says nothing was tagged" \
    "$(run_on "$W" 0.1.0 --dry-run | grep -c 'Nothing was tagged')" "1"

# ---------------------------------------------------------------------------
# The green path, and what it carries onto the release.
# ---------------------------------------------------------------------------
W="$(world green)"
check "an all green commit is releasable" "$(status_on "$W" 0.1.0 --dry-run)" "0"
check "and the notes carry the commit being tagged" \
    "$(run_on "$W" 0.1.0 --dry-run | grep -c '^Commit: 0e71051627c6a43a6e7e7e08b3a997895cc969b5$')" "1"
check "and the notes carry every check by name with its conclusion" \
    "$(run_on "$W" 0.1.0 --dry-run | grep -cE '^  (Shell suites on (macos|ubuntu)-latest|Secrets in the history): success')" "3"
check "and the notes carry the history scan's own MEASUREMENT, not a claim about it" \
    "$(run_on "$W" 0.1.0 --dry-run | grep -c '143 of 143 committed blob')" "1"
check "and the notes say why it is 0.x" \
    "$(run_on "$W" 0.1.0 --dry-run | grep -c 'backstage#12')" "1"
check "and a dry run creates nothing" \
    "$(run_on "$W" 0.1.0 --dry-run | grep -c 'WOULD TAG')" "1"

# ---------------------------------------------------------------------------
# An explicit SHA is honoured, so a release can be cut at a commit that is not
# the tip without the remote deciding it.
# ---------------------------------------------------------------------------
W="$(world explicit)"
check "an explicit commit is tagged instead of the remote's main" \
    "$(run_on "$W" 0.1.0 --sha deadbeefdeadbeefdeadbeefdeadbeefdeadbeef --dry-run | grep -c '^Commit: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef$')" "1"
check "and the remote's main is NOT what it tagged" \
    "$(run_on "$W" 0.1.0 --sha deadbeefdeadbeefdeadbeefdeadbeefdeadbeef --dry-run | grep -c '0e71051')" "0"
check "and --sha with nothing after it is refused" \
    "$(status_on "$W" 0.1.0 --sha)" "1"

# ---------------------------------------------------------------------------
# The real paths, once, so the seam is not the only thing ever measured (L246).
# No fake directory at all: it resolves the real remote and reads the real API.
# ---------------------------------------------------------------------------
REAL="$(bash "$TARGET" 0.1.0 --dry-run 2>&1)"
check "against the real remote and the real API, the tree is releasable" \
    "$(printf '%s' "$REAL" | grep -c 'WOULD TAG 0.1.0')" "1"
check "and the real run reads the real history scan" \
    "$(printf '%s' "$REAL" | grep -c 'committed blob')" "1"

harness_end
