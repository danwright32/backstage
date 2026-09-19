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

ONE SECRET IS ONE FINDING, however many build products carry it (backstage#19).
Walking the build output is the point, but on 2026-09-19 one fixture line came
back as 44 findings in 3 files: 4 in the source and 40 in the compiled object
file and the test bundle, which hold the same string. A report where the line
that matters is buried under forty copies of itself is one people learn to skim
(L36), and a count inflated tenfold by build output reads as ten times the
problem. So occurrences of the SAME value are grouped: the ones in files git
tracks are listed, and the rest are counted beside them with the first named.

A VALUE THAT APPEARS ONLY IN UNTRACKED FILES IS REPORTED IN FULL, because that is
the case where the build product is the only evidence there is, and a secret can
reach one by routes the source never shows.

WHAT IS TRACKED IS ASKED OF GIT, with git's own environment variables stripped,
because an inherited GIT_DIR beats `git -C` and this runs from a pre push hook,
which is where git exports them. A tree that is not a checkout cannot be asked,
so nothing is grouped there and the run SAYS so rather than leaving a reader to
infer it from a longer list (L98).
"""
import os
import re
import subprocess
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

# Skipped, each for its reason (L362):
#   .git                             not the working tree; it holds every historical version
#   SDKExplicitPrecompiledModules    precompiled copies of APPLE'S OWN frameworks that the build
#                                    drops into the cache. Apple's bytes, not this repository's,
#                                    and their binary noise matches the mailbox rule. ONLY this
#                                    folder: our own compiled output beside it is still read,
#                                    because a secret can reach it by routes the source hides
#                                    (Dan's sign off 2026-09-19, L324).
SKIP_DIRS = {".git", "SDKExplicitPrecompiledModules"}


def mailbox_is_reserved(address):
    domain = address.rsplit("@", 1)[1].lower()
    local = address.rsplit("@", 1)[0].lower()
    # A SUBDOMAIN of a reserved domain is reserved too (backstage#18, Dan's sign off 2026-09-19):
    # everything beneath example.com belongs to it. Matched as the whole domain or a dot then the
    # whole domain, never a bare suffix, so notexample.com and example.com.attacker.org, both real
    # and registrable, are still refused. That is the risk of widening a privacy control, and a
    # test pins each shape.
    if any(domain == d or domain.endswith("." + d) for d in RESERVED_DOMAINS):
        return True
    if domain.endswith(RESERVED_TLDS):
        return True
    if local == "git" and domain in CODE_HOSTS:
        return True
    return False


def findings_in(text):
    """Every finding in one file's text, as (rule, line number, the matched value).

    The value is carried so that occurrences of the SAME secret can be grouped.
    It is never printed, and never leaves this process: a guard that reports a
    leaked secret by quoting it has leaked it a second time (L222).
    """
    found = []
    for number, line in enumerate(text.splitlines(), start=1):
        for rule, pattern in CONTENT_RULES:
            match = pattern.search(line)
            if match:
                found.append((rule, number, match.group()))
        for address in EMAIL.findall(line):
            if not mailbox_is_reserved(address):
                found.append(("mailbox", number, address))
    return found


def tracked_files(root):
    """Every path git holds in its index for the tree at root, relative to root.

    Returns (paths, why not). `paths` is None when the question could not be
    asked at all, which is a different fact from an empty index: a checkout with
    nothing staged HAS been asked and answered.

    THE TWO WAYS IT CANNOT BE ASKED ARE NAMED SEPARATELY (L11). A tree that is
    not a checkout and a machine with no git are different causes, and a message
    saying "not a git checkout" on a machine that simply has no git claims
    something this never measured.

    GIT'S OWN ENVIRONMENT VARIABLES ARE STRIPPED. An inherited GIT_DIR BEATS the
    -C, and git exports GIT_DIR to its hooks, which is where this runs.
    """
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    try:
        finished = subprocess.run(["git", "-C", root, "ls-files", "-z"],
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  env=environment, check=False)
    except OSError:
        return None, "git is not on this machine"
    if finished.returncode != 0:
        return None, "%s is not a git checkout" % root
    listed = finished.stdout.decode("utf-8", errors="replace").split("\0")
    return {path for path in listed if path}, None


def grouped(findings, tracked):
    """The findings to LIST, and how many occurrences each one stands for.

    Grouped by rule and value, because that pair is what one secret is. A
    credential store has no value to match on, so its group is its file name,
    which is the thing the rule fired on.

    Returns (rows, suppressed), where a row is (rule, path, line, copies, first
    copy) and `copies` counts occurrences of the same value in files git does
    not track.
    """
    groups = {}
    for rule, path, number, value in findings:
        key = (rule, value if value is not None else os.path.basename(path))
        groups.setdefault(key, []).append((rule, path, number))

    rows = []
    suppressed = 0
    for occurrences in groups.values():
        listed = [o for o in occurrences if o[1] in tracked]
        copies = [o for o in occurrences if o[1] not in tracked]
        if not listed:
            # NOTHING TRACKED CARRIES THIS VALUE, so every occurrence is
            # reported: the build product is the only evidence there is.
            rows.extend((rule, path, number, 0, None) for rule, path, number in copies)
            continue
        suppressed += len(copies)
        first_copy = sorted(copies, key=lambda o: (o[1], o[2]))[0] if copies else None
        for index, (rule, path, number) in enumerate(sorted(listed, key=lambda o: (o[1], o[2]))):
            # The copies are counted once for the group, against its first
            # source, rather than repeated against each one.
            rows.append((rule, path, number, len(copies) if index == 0 else 0, first_copy))
    return sorted(rows), suppressed


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
                findings.append(("credential-store", relative, 0, None))
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
            for rule, number, value in findings_in(text):
                findings.append((rule, relative, number, value))

    if examined == 0:
        print("REFUSED: examined 0 files under %s, so nothing was checked." % root)
        return 2

    if findings:
        tracked, ungroupable = tracked_files(root)
        rows, suppressed = grouped(findings, tracked if tracked is not None else set())
        files = sorted({path for _, path, _, _, _ in rows})
        print("REFUSED: %d finding(s) in %d file(s). The value itself is never printed."
              % (len(rows), len(files)))
        if suppressed:
            print("    %d further occurrence(s) hold a value already reported above and are"
                  % suppressed)
            print("    counted against it rather than listed: they are copies, and the")
            print("    tracked file named above is where the remedy is.")
        if ungroupable:
            # SAID, NOT INFERRED, AND IT NAMES WHICH QUESTION WENT UNASKED.
            # Without this line a reader has no way to tell a tree whose copies
            # could not be grouped from one that had none (L98, L11).
            print("    %s, so nothing could be asked about what is tracked and no"
                  % ungroupable)
            print("    occurrence was grouped as a copy of another.")
        for rule, path, number, copies, first_copy in rows:
            where = "%s line %d" % (path, number) if number else path
            print("  RULE %-22s %s" % (rule, where))
            if copies:
                _, copy_path, copy_number = first_copy
                print("      + %d untracked copy(ies) of this value, the first at %s"
                      % (copies, "%s line %d" % (copy_path, copy_number) if copy_number
                         else copy_path))
        return 1

    print("clean: examined %d files, 0 findings." % examined)
    return 0


if __name__ == "__main__":
    sys.exit(main())
