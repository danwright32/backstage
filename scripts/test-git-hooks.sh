#!/bin/bash
# The pre push hook must refuse a real push whose suite is red or whose tree
# holds a credential, and it must judge the tree BEING PUSHED.
#
# backstage#1. Measured with real pushes to a real (throwaway, local) remote
# rather than by calling the hook directly, because what matters is the guarantee
# git actually gives, not the one the hook would give if invoked by hand (L82).
#
# THE ONE THAT BIT THE PORT SOURCE (ovation#138, L398): its hook derived the tree
# to judge from the hook FILE's own location, and core.hooksPath had been left as
# an absolute path into the primary checkout. A push from a worktree therefore ran
# the primary checkout's hook against the primary checkout's tree, and the branch
# being pushed was never looked at. It failed in both directions, and the one that
# bit was a green branch refused for a fault that existed only somewhere else.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO_ROOT="$(pwd)"
. "$(dirname "$0")/lib/test-harness.sh"
harness_begin "git hook tests" 14

TARGET="scripts/git-hooks/pre-push"
require_target "$TARGET"
require_target "scripts/install-git-hooks.sh"
harness_temp_dir WORK

says() { if printf '%s' "$1" | grep -qF "$2"; then echo yes; else echo no; fi; }
# A `case` inside a command substitution inside an argument does not parse, so
# the shape is decided in a named function instead of inline.
shape_of_path() { case "$1" in /*) echo absolute;; *) echo relative;; esac; }

# A throwaway repository carrying the REAL guard and runner, plus one trivial
# suite so the runner has something to find. Identity is set LOCALLY: a fixture
# writing to the shared config would author every later commit in every checkout
# on this machine (L435, and the incident recorded in lib/test-harness.sh).
make_repo() {
    [ -n "$WORK" ] || exit 1
    local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d/scripts/lib" "$d/scripts/git-hooks"
    cp "$REPO_ROOT/scripts/check-secrets.sh" "$d/scripts/"
    cp "$REPO_ROOT/scripts/run-tests.sh" "$d/scripts/"
    cp "$REPO_ROOT/scripts/git-hooks/pre-push" "$d/scripts/git-hooks/"
    cp "$REPO_ROOT/scripts/install-git-hooks.sh" "$d/scripts/"
    chmod +x "$d/scripts/"*.sh "$d/scripts/git-hooks/pre-push"
    printf '#!/bin/bash\nexit 0\n' > "$d/scripts/test-trivial.sh"
    chmod +x "$d/scripts/test-trivial.sh"
    printf 'public struct Placeholder {}\n' > "$d/Source.swift"
    git -C "$d" init -q -b main
    git -C "$d" config user.email "suite@example.com"
    git -C "$d" config user.name "suite"
    ( cd "$d" && ./scripts/install-git-hooks.sh > /dev/null 2>&1 )
    git -C "$d" add -A
    git -C "$d" commit -qm "first"
    git init -q --bare "$d.remote.git"
    git -C "$d" remote add origin "$d.remote.git"
    printf '%s\n' "$d"
}

OUT=""; CODE=0
push() { OUT="$(git -C "$1" push origin main 2>&1)"; CODE=$?; }

# --- a green tree really is pushed ---
D="$(make_repo green)"
push "$D"
check "a green tree with no credential is pushed" "$CODE" "0"
check "the remote received the branch" \
      "$(git -C "$D.remote.git" rev-parse --verify -q main > /dev/null && echo yes || echo no)" "yes"

# --- the installer, whose one past defect was an absolute path ---
D="$(make_repo installed)"
check "the installer sets hooksPath" \
      "$(git -C "$D" config --get core.hooksPath)" "scripts/git-hooks"
HOOKS_PATH="$(git -C "$D" config --get core.hooksPath)"
check "hooksPath is relative, never absolute" "$(shape_of_path "$HOOKS_PATH")" "relative"

# --- a credential in the tree refuses the push ---
D="$(make_repo secret)"
printf 'let s = "%s"\n' "GOCSPX-""bbbbbbbbbbbbbbbbbbbbbbbb" > "$D/Leak.swift"
git -C "$D" add -A && git -C "$D" commit -qm "leak"
push "$D"
check "a credential in the tree refuses the push" \
      "$( [ "$CODE" -ne 0 ] && echo refused || echo pushed )" "refused"
check "the refusal names the rule that fired" "$(says "$OUT" "oauth-client-secret")" "yes"
check "the refusal never prints the value" "$(says "$OUT" "bbbbbbbbbbbbbbbbbbbbbbbb")" "no"
check "a refused push leaves the remote untouched" \
      "$(git -C "$D.remote.git" rev-parse --verify -q main > /dev/null && echo yes || echo no)" "no"

# --- a red suite refuses the push ---
D="$(make_repo red)"
printf '#!/bin/bash\nexit 1\n' > "$D/scripts/test-trivial.sh"
chmod +x "$D/scripts/test-trivial.sh"
git -C "$D" add -A && git -C "$D" commit -qm "red"
push "$D"
check "a red suite refuses the push" "$( [ "$CODE" -ne 0 ] && echo refused || echo pushed )" "refused"
check "the refusal names the failing suite" "$(says "$OUT" "test-trivial.sh")" "yes"

# JUDGED BY EXIT CODE, never by a reassuring last line (L184).
D="$(make_repo liar)"
printf '#!/bin/bash\necho "all tests passed"\nexit 1\n' > "$D/scripts/test-trivial.sh"
chmod +x "$D/scripts/test-trivial.sh"
git -C "$D" add -A && git -C "$D" commit -qm "liar"
push "$D"
check "a suite claiming success but exiting non zero still refuses" \
      "$( [ "$CODE" -ne 0 ] && echo refused || echo pushed )" "refused"

# TWO OUTCOMES, TWO MESSAGES (L11, L622). A suite that RAN and failed and a
# suite that never ran are different facts, and the second is "unmeasured"
# rather than "red". Found on this hook's own first real push, which called a
# non executable suite a red one and would have sent somebody hunting a test
# failure that did not exist.
D="$(make_repo unmeasured)"
printf 'not executable\n' > "$D/scripts/test-cannot-run.sh"
chmod -x "$D/scripts/test-cannot-run.sh"
git -C "$D" add -A && git -C "$D" commit -qm "unrunnable"
push "$D"
check "a suite that never ran is called unmeasured" "$(says "$OUT" "UNMEASURED")" "yes"
check "a suite that never ran is not called red" "$(says "$OUT" "the suite is red")" "no"

# THE TREE BEING PUSHED, not the tree the hook file lives in (L398, ovation#138).
# The hook here is deliberately given a DIFFERENT repository's guard to find if
# it were to resolve its scripts from anywhere but its own working directory.
D="$(make_repo cwd)"
printf 'let s = "%s"\n' "GOCSPX-""cccccccccccccccccccccccc" > "$D/Leak.swift"
git -C "$D" add -A && git -C "$D" commit -qm "leak"
( cd / && OUT="$(git -C "$D" push origin main 2>&1)"; [ $? -ne 0 ] && echo refused || echo pushed ) > "$WORK/cwd.txt"
check "the hook judges its own tree whatever the caller's directory" \
      "$(cat "$WORK/cwd.txt")" "refused"

harness_end
