#!/bin/bash
# A script that GENERATES a Swift manifest must derive the dependency's identity
# and its path, never spell either out (backstage#30).
#
# scripts/test-scopes-required.sh builds a throwaway consumer against this
# repository. SwiftPM takes a path dependency's IDENTITY from the last component
# of the path, and a git worktree's directory is named after the branch, never
# after the repository, so a manifest naming the identity as a literal is true of
# one checkout on one Mac. backstage#28 was exactly that: the suite passed in the
# primary checkout and refused every push made from a worktree, reporting the no
# default scopes rule as broken. The fault reads as a security rule failing
# rather than as a test confused about its own name, so it costs a diagnosis
# every time.
#
# #29 closed that one site. This closes the class (L30). The rule is written as
# the REASON rather than as one file's name (L362): in a generated manifest both
# the identity and the path must come from something derived at run time, so the
# manifest says the same thing from wherever the checkout happens to sit.
#
# IT NAMES ITS OWN NEEDLE, so it must not match itself. The shapes it refuses are
# assembled from pieces at run time and written into fixtures, and whole comment
# lines are dropped before the scan, the same rule scripts/lib/workflow-text.sh
# applies to a workflow file: a sentence ABOUT a manifest line is not one (L135,
# L245). The limit said out loud: a `#` at the start of a line inside a heredoc
# is dropped too. No manifest written here has one, because Swift's comment is
# `//`.
#
# THE SECOND LIMIT SAID OUT LOUD: this reads the manifest TEXT. An identity built
# by assigning a literal to a shell variable first and expanding that variable is
# derived as far as this can see. What it catches is the shape that actually
# shipped, and the positive control below keeps it honest about having looked at
# anything at all.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. "$(dirname "$0")/lib/test-harness.sh"
harness_begin "package identity tests" 11

require_target "scripts/test-scopes-required.sh"
harness_temp_dir WORK

# Assembled so this file holds no instance of what it refuses.
Q='"'
ARG_ID="package:"
ARG_PATH=".package(path:"
# The same two tokens as one pattern, with the path one's own punctuation escaped
# so it is read as text rather than as a group.
ARG_RE="(package:|\\.package\\(path:)[[:space:]]*${Q}[^${Q}]*${Q}"

# Everything a script under <dir> hands a manifest as an identity or a path, as
# `<file>:<line>:<text>`, comment lines dropped. Both questions read the same
# text through the same pass, because two scanners each deciding what a manifest
# line is are two rules that drift (L370).
manifest_arguments() {
    local dir="$1" file hit num body match
    while IFS= read -r file; do
        while IFS= read -r hit; do
            num="${hit%%:*}"
            body="${hit#*:}"
            [[ "$body" =~ ^[[:space:]]*# ]] && continue
            while IFS= read -r match; do
                [ -n "$match" ] || continue
                printf '%s:%s:%s\n' "$file" "$num" "$match"
            done < <(printf '%s\n' "$body" | grep -oE "$ARG_RE")
        done < <(grep -nE "$ARG_RE" "$file" 2>/dev/null)
    done < <(find "$dir" -type f \( -name '*.sh' -o -name '*.py' \) -not -path '*/git-hooks/*' | sort)
}

# A value is DERIVED when it is built at run time. A quoted run with no expansion
# in it is a literal, and a literal is what was true of one Mac.
literal_arguments() {
    manifest_arguments "$1" | grep -vE '\$' || true
}

count() { printf '%s' "$1" | grep -c . || true; }
names() { if printf '%s' "$1" | grep -qF "$2"; then echo yes; else echo no; fi; }

# ---------------------------------------------------------------------------
# THE REAL TREE. Asserted first, so the fixtures below are calibrated against the
# repository as it is rather than against a shape chosen to make them fire (L48).
check "no script here spells a manifest identity or path out" \
    "$(literal_arguments "$PWD/scripts")" ""

# A SCAN THAT MATCHED NOTHING IS NOT A CLEAN TREE (L98). The existing suite is
# the positive control the issue asks for: it really does generate a manifest,
# so a scan that cannot see its two arguments is measuring nothing, and would go
# on reporting clean through any rewrite of it.
REAL="$(manifest_arguments "$PWD/scripts")"
check "the scan found the manifest arguments that are really there" \
    "$( [ "$(count "$REAL")" -ge 2 ] && echo found || echo "found $(count "$REAL")")" "found"
check "and they are in the suite that builds a consumer" \
    "$(names "$REAL" "scripts/test-scopes-required.sh")" "yes"
check "the identity argument is among them" "$(names "$REAL" "$ARG_ID")" "yes"
check "the path argument is among them" "$(names "$REAL" "$ARG_PATH")" "yes"

# ---------------------------------------------------------------------------
# A SPELLED OUT IDENTITY, which is backstage#28 as it actually happened.
FIX="$WORK/scripts"
mkdir -p "$FIX"
{
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'cat > "$C/Package.swift" <<EOF'
    printf '    dependencies: [%s %s$LINKED%s)],\n' "$ARG_PATH" "$Q" "$Q"
    printf '    targets: [.executableTarget(name: %sConsumer%s,\n' "$Q" "$Q"
    printf '        dependencies: [.product(name: %sBackstageGoogle%s, %s %sbackstage%s)])]\n' \
        "$Q" "$Q" "$ARG_ID" "$Q" "$Q"
    printf '%s\n' 'EOF'
} > "$FIX/test-spelled-out.sh"

OUT="$(literal_arguments "$FIX")"
check "a manifest naming the identity as a literal is refused" \
    "$( [ -n "$OUT" ] && echo refused || echo allowed)" "refused"
check "and the file it is in is named" "$(names "$OUT" "test-spelled-out.sh")" "yes"

# ---------------------------------------------------------------------------
# A SPELLED OUT PATH is the same fault wearing the other hat: a path written down
# is a path that is true of one checkout on one Mac.
{
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'cat > "$C/Package.swift" <<EOF'
    printf '    dependencies: [%s %s/Users/someone/Apps/backstage%s)],\n' "$ARG_PATH" "$Q" "$Q"
    printf '%s\n' 'EOF'
} > "$FIX/test-spelled-out-path.sh"
check "a manifest naming the path as a literal is refused too" \
    "$(names "$(literal_arguments "$FIX")" "test-spelled-out-path.sh")" "yes"

# ---------------------------------------------------------------------------
# WHAT IT MUST PRESERVE (L104). A derived pair is what the repository actually
# writes, and a guard that refuses it would be refused into being switched off.
rm -f "$FIX/test-spelled-out.sh" "$FIX/test-spelled-out-path.sh"
{
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'LINKED_ID="$(basename "$LINKED")"'
    printf '%s\n' 'cat > "$C/Package.swift" <<EOF'
    printf '    dependencies: [%s %s$LINKED%s)],\n' "$ARG_PATH" "$Q" "$Q"
    printf '        dependencies: [.product(name: %sX%s, %s %s$LINKED_ID%s)])]\n' \
        "$Q" "$Q" "$ARG_ID" "$Q" "$Q"
    printf '%s\n' 'EOF'
} > "$FIX/test-derived.sh"
check "a manifest deriving both is accepted" "$(literal_arguments "$FIX")" ""
check "and the scan did examine it, rather than finding nothing to read" \
    "$(names "$(manifest_arguments "$FIX")" "test-derived.sh")" "yes"

# A SENTENCE ABOUT A MANIFEST IS NOT A MANIFEST. Without this the rule cannot be
# explained in any file it scans, which is how a guard ends up matching itself
# and every document describing it (L245).
printf '%s\n' '#!/bin/bash' "# never write ${ARG_ID} ${Q}backstage${Q} here" > "$FIX/test-prose.sh"
check "a comment naming the shape is not a manifest line" "$(literal_arguments "$FIX")" ""

harness_end
