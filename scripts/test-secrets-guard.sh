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
harness_begin "secrets guard tests" 30

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
