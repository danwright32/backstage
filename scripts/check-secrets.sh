#!/usr/bin/env python3
''''exec python3 "$0" "$@" #'''
__doc__ = """Refuse if a credential or a real mailbox appears anywhere in the tree.

backstage#1. This repository is PUBLIC for the whole build, and its entire
subject matter is a Google OAuth client. A committed secret in a public
repository is compromised the moment it is pushed, not when somebody notices.

THE DESIGN THIS DELIBERATELY DOES NOT COPY. Ovation's identity guard DERIVES its
needles from the live client and venue populations that exist at its phase, and
treats an empty derivation as a REFUSAL rather than a pass. backstage holds no
such population by construction, so a straight copy would refuse for ever here,
and the obvious repair (letting an empty derivation pass) would reproduce exactly
the defect the original was built to prevent: a guard that examines nothing and
reports clean (L501, L217).

So the needles here are FIXED, and what stands in for that refusal is this: a run
that examined ZERO files is a REFUSAL. Nothing to check is not a pass (L98).

WHAT IT NEVER PRINTS: the value it matched. Its output goes into transcripts,
terminal scrollback and CI logs, by a route no file scanner inspects (L222). A
guard that reports a leaked secret by quoting it has leaked it a second time, to
a place with no retention policy. Rule names, paths and line numbers only.

IT NAMES WHICH RULE FIRED. A fault big enough makes every rule fire, and a
message saying only that something was found cannot tell that apart from one
precise hit (L154).

IT WALKS THE DIRECTORY, not `git ls-files`. The highest risk content on a disk is
exactly what .gitignore excludes, and an ignore entry means "per machine", never
"do not look" (L250, L234). `.git` itself IS skipped, because it is not the
working tree and holds every historical version of every file.

EXEMPTIONS ARE WRITTEN AS THE REASON FOR EXEMPTING, never as one named case, so
they keep covering the second case that satisfies the same reason (L362).
"""
import os
import re
import sys

# Domains reserved by RFC 2606 and RFC 6761 precisely so that they can be written
# down without reaching anybody. An address at one of these is documentation.
RESERVED_DOMAINS = ("example.com", "example.org", "example.net")
RESERVED_TLDS = (".invalid", ".test", ".example", ".localhost")

# THE REASON, not the case: an SSH login at a code host is a transport identity
# that receives no mail. Any host offering git over SSH satisfies it.
CODE_HOSTS = ("github.com", "gitlab.com", "bitbucket.org", "codeberg.org")

EMAIL = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")

CONTENT_RULES = (
    # A Google OAuth client secret carries its own documented prefix.
    ("oauth-client-secret", re.compile(r"GOCSPX-[A-Za-z0-9_\-]{20,}")),
    ("oauth-client-id", re.compile(r"\d{6,}-[A-Za-z0-9_\-]{10,}\.apps\.googleusercontent\.com")),
    # ya29. is an access token, 1//0 a refresh token. Both are bearer values.
    ("oauth-token", re.compile(r"(?:ya29\.|1//0)[A-Za-z0-9_\-]{20,}")),
)

# Named for what they ARE, so a new file matching the reason is caught too.
CREDENTIAL_FILENAMES = re.compile(
    r"^(credentials|client_secret.*|token|tokens|refresh_token)\.json$|"
    r"\.(keychain|keychain-db|p12|pfx|pem|key)$",
    re.IGNORECASE,
)

SKIP_DIRS = {".git"}


def mailbox_is_reserved(address):
    domain = address.rsplit("@", 1)[1].lower()
    local = address.rsplit("@", 1)[0].lower()
    if domain in RESERVED_DOMAINS or domain.endswith(RESERVED_TLDS):
        return True
    if local == "git" and domain in CODE_HOSTS:
        return True
    return False


def findings_in(text):
    """Every finding in one file's text, as (rule, line number)."""
    found = []
    for number, line in enumerate(text.splitlines(), start=1):
        for rule, pattern in CONTENT_RULES:
            if pattern.search(line):
                found.append((rule, number))
        for address in EMAIL.findall(line):
            if not mailbox_is_reserved(address):
                found.append(("mailbox", number))
    return found


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    if not os.path.isdir(root):
        print("REFUSED: %s is not a directory that can be read, so nothing was checked." % root)
        return 2

    examined = 0
    findings = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            relative = os.path.relpath(path, root)
            if os.path.islink(path):
                continue
            examined += 1
            if CREDENTIAL_FILENAMES.search(name):
                findings.append(("credential-store", relative, 0))
            try:
                with open(path, "rb") as handle:
                    # Decoded with replacement rather than skipped on a bad byte:
                    # a scanner that gives up on a file holding one binary byte
                    # stops examining it and says so in a way that reads as clean
                    # (L329).
                    text = handle.read().decode("utf-8", errors="replace")
            except OSError as error:
                print("REFUSED: %s could not be read (%s), so the tree was not fully checked."
                      % (relative, error.__class__.__name__))
                return 2
            for rule, number in findings_in(text):
                findings.append((rule, relative, number))

    if examined == 0:
        print("REFUSED: examined 0 files under %s, so nothing was checked." % root)
        return 2

    if findings:
        files = sorted({path for _, path, _ in findings})
        print("REFUSED: %d finding(s) in %d file(s). The value itself is never printed."
              % (len(findings), len(files)))
        for rule, path, number in sorted(findings):
            where = "%s line %d" % (path, number) if number else path
            print("  RULE %-22s %s" % (rule, where))
        return 1

    print("clean: examined %d files, 0 findings." % examined)
    return 0


if __name__ == "__main__":
    sys.exit(main())
