#!/bin/bash
# The secrets guard must refuse a credential anywhere in the tree, must NAME
# which rule fired, must never print the value it found, and must refuse when it
# examined nothing.
#
# backstage#1. This repository is PUBLIC for the whole build (Dan, 2026-09-17:
# Actions is unlimited on a public repo and a private one bills macOS runners at
# ten times the rate), and its entire subject matter is a Google OAuth client.
#
# THE DESIGN THIS DELIBERATELY DOES NOT COPY. Ovation's identity guard DERIVES
# its needles from the live client and venue populations that exist at its phase,
# and treats an empty derivation as a REFUSAL. backstage holds no such population
# by construction, so that guard would refuse on every run here for ever, and the
# obvious repair (let an empty derivation pass) reproduces exactly the defect the
# original was built to prevent (L501). So the needles here are FIXED, and what
# stands in for the empty derivation refusal is a refusal when zero files were
# examined (L98).
#
# NO FIXTURE CARRIES A VALUE THAT COULD BE REAL. Each pattern is assembled from
# pieces at run time, so this file holds no literal run that the guard would
# match, and a suite holding a real credential would publish it (L155, L222).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. "$(dirname "$0")/lib/test-harness.sh"
harness_begin "secrets guard tests" 47

TARGET="scripts/check-secrets.sh"
require_target "$TARGET"
harness_temp_dir WORK

# Values shaped exactly like the real thing and belonging to nobody. Split so
# this file carries no matchable run of its own.
CLIENT_SECRET="GOCSPX-""aaaaaaaaaaaaaaaaaaaaaaaa"
CLIENT_ID="000000000000-""aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"".apps.googleusercontent.com"
ACCESS_TOKEN="ya29.""AaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAa"
REFRESH_TOKEN="1//0""AaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAa"
REAL_MAILBOX="someone""@""a-real-looking-domain.com"

tree() { [ -n "$WORK" ] || exit 1; local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s\n' "$d"; }
says() { if printf '%s' "$1" | grep -qF "$2"; then echo yes; else echo no; fi; }

OUT=""; CODE=0
run_guard() { OUT="$("$TARGET" "$1" 2>&1)"; CODE=$?; }

# A tree with one ordinary, harmless Swift file in it. Every refusal case below
# adds its fixture to a copy of THIS, so a case that fires proves the fixture is
# what fired it and not the emptiness of the tree.
ordinary() {
    local d; d="$(tree "$1")"
    cat > "$d/Ordinary.swift" <<'SWIFT'
import Foundation

/// Sends a message. Reach the maintainer at maintainer@example.com.
@available(macOS 13, *)
public struct Sender {
    public init() {}
}
SWIFT
    printf '%s\n' "$d"
}

# --- the healthy case, and what it must PRESERVE (L104) ---
D="$(ordinary clean)"
run_guard "$D"
check "a tree with no credential is accepted" "$CODE" "0"
check "an accepted tree names no rule" "$(says "$OUT" "RULE ")" "no"

# An address on a reserved example domain is documentation, not a mailbox.
D="$(ordinary example-domains)"
printf 'contact: nobody@example.org\nalso: nobody@example.net\n' > "$D/README.md"
run_guard "$D"
check "a reserved example domain is not a mailbox" "$CODE" "0"

# .invalid and .test are reserved by RFC 6761 and can never resolve.
D="$(ordinary reserved-tlds)"
printf 'a@fixture.invalid b@fixture.test\n' > "$D/Fixtures.swift"
run_guard "$D"
check "a reserved TLD is not a mailbox" "$CODE" "0"

# A SUBDOMAIN OF A RESERVED DOMAIN IS RESERVED TOO (backstage#18, Dan's sign off 2026-09-19).
# Everything beneath example.com belongs to it and can never resolve to a real mailbox, and it is
# the natural shape of a Message-ID's host, which is where the over match was found.
D="$(ordinary reserved-subdomain)"
printf 'id: <abc@mail.example.com>\nalso: x@a.b.example.org\n' > "$D/Threading.swift"
run_guard "$D"
check "an address under a reserved domain is documentation" "$CODE" "0"

# AND A REAL DOMAIN DRESSED AS ONE IS STILL REFUSED. A suffix test written carelessly accepts
# these, which is the whole risk of widening a privacy control, so each shape has its own case.
D="$(ordinary lookalike-suffix)"; printf 'to: %s\n' "someone""@""example.com.attacker.org" > "$D/A.swift"
run_guard "$D"
check "a real domain that merely CONTAINS a reserved one is refused" "$( [ "$CODE" -ne 0 ] && echo refused || echo allowed )" "refused"

D="$(ordinary lookalike-prefix)"; printf 'to: %s\n' "someone""@""notexample.com" > "$D/A.swift"
run_guard "$D"
check "a real domain that merely ENDS in the same letters is refused" "$( [ "$CODE" -ne 0 ] && echo refused || echo allowed )" "refused"

# APPLE'S PRECOMPILED SDK MODULES ARE NOT THIS REPOSITORY'S CONTENT (Dan's sign off 2026-09-19).
# The build drops precompiled copies of Apple's own frameworks into a folder of that name, and their
# binary noise contains strings the mailbox rule reads as addresses. They are Apple's bytes, not
# anything written here, so that one folder is skipped.
D="$(ordinary apple-sdk-cache)"
mkdir -p "$D/.build/out/SDKExplicitPrecompiledModules"
printf 'noise %s noise\n' "x""@""kx.hj" > "$D/.build/out/SDKExplicitPrecompiledModules/Spatial-ABC.pcm"
run_guard "$D"
check "Apple's precompiled SDK modules are not scanned" "$CODE" "0"

# THE SKIP IS THAT ONE FOLDER, NOT THE BUILD CACHE. Our own compiled code sits beside it and can
# carry a secret the source no longer shows, which is why the build cache is read at all (L324: a
# stand down condition no broader than its reason).
D="$(ordinary own-build-output)"
mkdir -p "$D/.build/out/Products/Debug"
printf 'k = %s\n' "$CLIENT_SECRET" > "$D/.build/out/Products/Debug/BackstageGoogle.o"
run_guard "$D"
check "our own compiled output beside it is still scanned" "$( [ "$CODE" -ne 0 ] && echo refused || echo allowed )" "refused"

# EXEMPT FOR A REASON, not as one named case (L362): a service SSH login is not
# a mailbox, because nobody receives mail at it.
D="$(ordinary ssh-login)"
printf 'git@github.com:danwright32/backstage.git\n' > "$D/.gitmodules"
run_guard "$D"
check "a service SSH login is not a mailbox" "$CODE" "0"

# --- each rule, refused BY NAME (L154) ---
D="$(ordinary secret)"; printf 'client_secret = "%s"\n' "$CLIENT_SECRET" > "$D/Config.swift"
run_guard "$D"
check "a client secret is refused" "$( [ "$CODE" -ne 0 ] && echo refused || echo allowed )" "refused"
check "a client secret names its rule" "$(says "$OUT" "oauth-client-secret")" "yes"
check "a client secret is never printed" "$(says "$OUT" "$CLIENT_SECRET")" "no"
check "a client secret names the file" "$(says "$OUT" "Config.swift")" "yes"

D="$(ordinary clientid)"; printf 'let id = "%s"\n' "$CLIENT_ID" > "$D/Client.swift"
run_guard "$D"
check "a client id is refused" "$( [ "$CODE" -ne 0 ] && echo refused || echo allowed )" "refused"
check "a client id names its rule" "$(says "$OUT" "oauth-client-id")" "yes"

D="$(ordinary access)"; printf '{"access_token":"%s"}\n' "$ACCESS_TOKEN" > "$D/response.json"
run_guard "$D"
check "an access token is refused" "$( [ "$CODE" -ne 0 ] && echo refused || echo allowed )" "refused"
check "an access token names its rule" "$(says "$OUT" "oauth-token")" "yes"

D="$(ordinary refresh)"; printf '{"refresh_token":"%s"}\n' "$REFRESH_TOKEN" > "$D/saved.json"
run_guard "$D"
check "a refresh token is refused" "$( [ "$CODE" -ne 0 ] && echo refused || echo allowed )" "refused"
check "a refresh token names its rule" "$(says "$OUT" "oauth-token")" "yes"

D="$(ordinary mailbox)"; printf 'to: %s\n' "$REAL_MAILBOX" > "$D/Fixture.swift"
run_guard "$D"
check "a real mailbox is refused" "$( [ "$CODE" -ne 0 ] && echo refused || echo allowed )" "refused"
check "a real mailbox names its rule" "$(says "$OUT" "mailbox")" "yes"
check "a real mailbox is never printed" "$(says "$OUT" "$REAL_MAILBOX")" "no"

D="$(ordinary store)"; printf '{}\n' > "$D/credentials.json"
run_guard "$D"
check "a credential store filename is refused" "$( [ "$CODE" -ne 0 ] && echo refused || echo allowed )" "refused"
check "a credential store names its rule" "$(says "$OUT" "credential-store")" "yes"

# --- where the highest risk content actually is ---
# An ignore entry means "per machine", never "do not look" (L250, L234). The
# port source records a real venue name sitting in an ignored path for days.
D="$(ordinary ignored)"
printf 'build/\n' > "$D/.gitignore"
mkdir -p "$D/build"
printf 'client_secret = "%s"\n' "$CLIENT_SECRET" > "$D/build/leaked.swift"
run_guard "$D"
check "an ignored path is still examined" "$( [ "$CODE" -ne 0 ] && echo refused || echo allowed )" "refused"

# .git holds every deleted version of every file and is not the working tree.
D="$(ordinary gitdir)"
mkdir -p "$D/.git"
printf 'client_secret = "%s"\n' "$CLIENT_SECRET" > "$D/.git/config"
run_guard "$D"
check "the git directory itself is skipped" "$CODE" "0"

# --- reporting completely, and refusing when it measured nothing ---
D="$(ordinary many)"
printf 'a = "%s"\n' "$CLIENT_SECRET" > "$D/one.swift"
printf 'b = "%s"\n' "$ACCESS_TOKEN" > "$D/two.swift"
run_guard "$D"
check "the first violation does not hide the second" "$(says "$OUT" "two.swift")" "yes"
check "both rules are named" "$(says "$OUT" "oauth-token")" "yes"

# --- one secret, forty copies of it (backstage#19) ---
#
# The guard walks the whole tree, .build included, on purpose: the riskiest
# content on a disk is what .gitignore excludes (L250). The cost showed on
# 2026-09-19, when one fixture line came back as 44 findings in 3 files, 4 in the
# source and 40 in the compiled object file and the test bundle, which carry the
# same string. A report where the one line that matters is buried under forty
# copies of itself is one people learn to skim (L36), and a count inflated
# tenfold by build output reads as ten times the problem.
#
# WHAT IS TRACKED IS ASKED OF GIT, so the fixture is a real checkout with the
# source staged. Staging is enough: ls-files reads the index, and an index needs
# no identity to write, which a commit would.
D="$(ordinary derived-copies)"
printf 'k = "%s"\n' "$CLIENT_SECRET" > "$D/Config.swift"
mkdir -p "$D/.build/Products/Debug"
printf 'noise %s noise\n' "$CLIENT_SECRET" > "$D/.build/Products/Debug/BackstageGoogle.o"
printf 'more %s more\n' "$CLIENT_SECRET" > "$D/.build/Products/Debug/Tests.xctest"
( cd "$D" && git init -q -b main >/dev/null 2>&1 && git add Config.swift Ordinary.swift ) || true
run_guard "$D"
check "a secret in a tracked source is still refused" "$( [ "$CODE" -ne 0 ] && echo refused || echo allowed )" "refused"
check "and the source it lives in is named" "$(says "$OUT" "Config.swift")" "yes"
check "and the copies are not listed one by one" \
    "$(printf '%s' "$OUT" | grep -c 'RULE ')" "1"
check "but the copies are counted rather than dropped" \
    "$(says "$OUT" "untracked copy")" "yes"
check "and the count the reader sees is not inflated by them" \
    "$(says "$OUT" "1 finding(s)")" "yes"
check "and grouping them still never prints the value" "$(says "$OUT" "$CLIENT_SECRET")" "no"

# A FINDING THAT EXISTS ONLY IN BUILD OUTPUT STAYS REPORTED IN FULL, because
# that is the case where the build output is the only evidence there is. A secret
# can reach a build product by routes the source never shows.
D="$(ordinary only-in-build)"
mkdir -p "$D/.build/Products/Debug"
printf 'k = "%s"\n' "$ACCESS_TOKEN" > "$D/.build/Products/Debug/Only.o"
( cd "$D" && git init -q -b main >/dev/null 2>&1 && git add Ordinary.swift ) || true
run_guard "$D"
check "a secret only in build output is refused" "$( [ "$CODE" -ne 0 ] && echo refused || echo allowed )" "refused"
check "and the build product is named, since it is the only evidence" \
    "$(says "$OUT" "Only.o")" "yes"

# TWO DIFFERENT SECRETS IN ONE SOURCE ARE TWO FINDINGS, not one group. The
# grouping is by value, so a report that collapsed them would hide one of them
# behind the other.
D="$(ordinary two-values-one-source)"
printf 'a = "%s"\nb = "%s"\n' "$CLIENT_SECRET" "$ACCESS_TOKEN" > "$D/Config.swift"
mkdir -p "$D/.build"
printf '%s %s\n' "$CLIENT_SECRET" "$ACCESS_TOKEN" > "$D/.build/Both.o"
( cd "$D" && git init -q -b main >/dev/null 2>&1 && git add Config.swift Ordinary.swift ) || true
run_guard "$D"
check "two different values in one file stay two findings" \
    "$(printf '%s' "$OUT" | grep -c 'RULE ')" "2"

# A TREE THAT IS NOT A CHECKOUT CANNOT BE ASKED WHAT IS TRACKED, and nothing is
# grouped away on a guess: every occurrence is reported, exactly as before. The
# run SAYS it could not group rather than leaving the reader to infer it (L98).
D="$(ordinary not-a-checkout)"
printf 'k = "%s"\n' "$CLIENT_SECRET" > "$D/Config.swift"
mkdir -p "$D/.build"
printf 'noise %s\n' "$CLIENT_SECRET" > "$D/.build/Copy.o"
run_guard "$D"
check "outside a checkout every occurrence is still reported" \
    "$(printf '%s' "$OUT" | grep -c 'RULE ')" "2"
check "and the run says why nothing was grouped" "$(says "$OUT" "not a git checkout")" "yes"

# AND A MACHINE WITH NO GIT IS A DIFFERENT CAUSE FROM A TREE THAT IS NOT A
# CHECKOUT (L11). Both leave the copies ungrouped, and a message naming the
# wrong one sends the reader to look at the tree when the fault is the machine.
# The fixture gives the guard a PATH holding python3 and nothing else, so git is
# genuinely absent rather than stubbed into saying something.
FAKE_BIN="$WORK/only-python"
mkdir -p "$FAKE_BIN"
ln -sf "$(command -v python3)" "$FAKE_BIN/python3"
OUT="$(PATH="$FAKE_BIN" "$TARGET" "$D" 2>&1)"; CODE=$?
check "with no git the findings are still all reported" \
    "$(printf '%s' "$OUT" | grep -c 'RULE ')" "2"
check "and the message names the machine, not the tree" \
    "$(says "$OUT" "git is not on this machine")" "yes"

# THE RULES COME FROM A LIBRARY, AND A MISSING ONE IS A REFUSAL (backstage#11).
# Both guards read what a secret is from scripts/lib/secret_rules.py, so neither
# can drift from the other (L370). An import that fell through would exit 1, and
# 1 is this script's code for A SECRET WAS FOUND, so a missing library would read
# as a finding rather than as a check that never ran (L11, L98). The fixture is a
# copy of the guard beside an empty lib, so the real one is never moved.
NOLIB="$WORK/no-library"
mkdir -p "$NOLIB/lib"
cp "$TARGET" "$NOLIB/check-secrets.sh"
OUT="$("$NOLIB/check-secrets.sh" "$D" 2>&1)"; CODE=$?
check "without its rules the guard refuses rather than reporting a finding" "$CODE" "2"
check "and it names the library that could not be read" \
    "$(says "$OUT" "secret_rules.py")" "yes"

# NOTHING TO EXAMINE IS NOT A PASS (L98). This is what stands in for the port
# source's empty derivation refusal.
D="$(tree empty)"
run_guard "$D"
check "a tree with no files is refused, not passed" "$( [ "$CODE" -ne 0 ] && echo refused || echo allowed )" "refused"
check "an empty tree says it examined nothing" "$(says "$OUT" "examined")" "yes"

# A target that cannot be read is refused rather than reported clean.
run_guard "$WORK/does-not-exist-at-all"
check "an unreadable target is refused" "$( [ "$CODE" -ne 0 ] && echo refused || echo allowed )" "refused"

harness_end
