#!/bin/bash
# A consumer that names no Gmail scopes must NOT COMPILE (backstage#3).
#
# The rule is that each consumer states the permissions it wants at its own call site, where somebody
# reviewing that consumer can see them. A runtime refusal is one nobody meets until the path runs, and
# a default list is one consumers silently inherit, so the requirement has to be a compile error, and
# a compile error can only be proved by compiling something (L407: a constraint recorded only as a
# comment is enforced by nothing).
#
# So this builds a throwaway consumer package against this repository twice. First WITH scopes, which
# must build: without that control, a consumer that failed for any reason at all (a broken package, a
# bad manifest, a missing toolchain) would satisfy the negative case below (L159). Then WITHOUT, which
# must fail, and fail naming the scopes parameter, so a failure for some other reason is not mistaken
# for this one (L140).
#
# macOS only: the package imports AppKit and Network. Elsewhere the three checks are reported as NOT
# RUN rather than as passes, and counted either way, so the suite's count cannot shrink (L411, L288).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO_ROOT="$(pwd)"
. "$(dirname "$0")/lib/test-harness.sh"
harness_begin "scopes required tests" 3
require_target "Sources/BackstageGoogle/GmailAuthManager.swift"
harness_temp_dir WORK

if [ "$(uname -s)" != "Darwin" ]; then
    echo "NOT RUN HERE: this package is macOS only, so a consumer cannot be built on $(uname -s)."
    check "a consumer naming its scopes builds (not run: not macOS)" "unmeasurable" "unmeasurable"
    check "a consumer naming none does not (not run: not macOS)" "unmeasurable" "unmeasurable"
    check "and fails for the scopes reason (not run: not macOS)" "unmeasurable" "unmeasurable"
    harness_end
fi

# The consumer depends on this repository through a symlink whose name is deliberately NOT
# `backstage`, so every run exercises the case that used to break the suite (backstage#28): SwiftPM
# takes a path dependency's IDENTITY from the last path component, and a git worktree's directory is
# named after the branch, never after the repository. A symlink is enough, because SwiftPM reads the
# link's own name and not the path it resolves to, which was measured rather than assumed.
LINKED="$WORK/not-named-after-this-repo"
ln -s "$REPO_ROOT" "$LINKED"
# The identity is DERIVED from the very path handed to .package(path:), by the rule SwiftPM itself
# uses, so the two cannot disagree however the directory is named (L41). Spelling it out instead is
# what broke: it read `backstage`, which is true of one checkout on one Mac.
LINKED_ID="$(basename "$LINKED")"

C="$WORK/consumer"
mkdir -p "$C/Sources/Consumer"
cat > "$C/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Consumer",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$LINKED")],
    targets: [.executableTarget(name: "Consumer",
                                dependencies: [.product(name: "BackstageGoogle", package: "$LINKED_ID")])]
)
EOF

build() { ( cd "$C" && swift build --scratch-path "$WORK/build" 2>&1 ); }

cat > "$C/Sources/Consumer/main.swift" <<'EOF'
import Foundation
import BackstageGoogle
@MainActor func make() throws -> GmailAuthManager {
    try GmailAuthManager(credentialsDirectory: URL(fileURLWithPath: "/tmp"),
                         scopes: ["https://www.googleapis.com/auth/gmail.send"],
                         productName: "Consumer")
}
EOF
GOOD_OUT="$(build)"; GOOD=$?
check "a consumer naming its scopes builds" "$GOOD" "0"
[ "$GOOD" -eq 0 ] || printf '%s\n' "$GOOD_OUT" | tail -15

cat > "$C/Sources/Consumer/main.swift" <<'EOF'
import Foundation
import BackstageGoogle
@MainActor func make() throws -> GmailAuthManager {
    try GmailAuthManager(credentialsDirectory: URL(fileURLWithPath: "/tmp"),
                         productName: "Consumer")
}
EOF
BAD_OUT="$(build)"; BAD=$?
check "a consumer naming no scopes does not build" "$([ "$BAD" -ne 0 ] && echo refused || echo built)" "refused"
# PRESENT, not counted: the build prints the same diagnostic more than once, so a count asserts how
# the output is laid out rather than what it says (L103).
check "and it fails because the scopes are missing, not for another reason" \
    "$(printf '%s' "$BAD_OUT" | grep -q "missing argument for parameter 'scopes'" && echo yes || echo no)" "yes"

harness_end
