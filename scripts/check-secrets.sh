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

# THE RULES LIVE IN ONE PLACE, because a second guard reads every blob ever
# committed with the same question (backstage#11), and two guards each deciding
# what a secret is are two rules that drift (L370).
#
# IMPORTED, OR REFUSED. An ImportError that fell through would exit 1, and 1 is
# this script's code for "a secret was found", so a missing library would read
# as a finding rather than as a check that could not run (L11, L98).
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
try:
    from secret_rules import CREDENTIAL_FILENAMES, findings_in
except ImportError as error:
    print("REFUSED: scripts/lib/secret_rules.py could not be imported (%s)." % error)
    print("    The rules this guard applies live there, so nothing was checked.")
    sys.exit(2)


# Skipped, each for its reason (L362):
#   .git                             not the working tree; it holds every historical version
#   SDKExplicitPrecompiledModules    precompiled copies of APPLE'S OWN frameworks that the build
#                                    drops into the cache. Apple's bytes, not this repository's,
#                                    and their binary noise matches the mailbox rule. ONLY this
#                                    folder: our own compiled output beside it is still read,
#                                    because a secret can reach it by routes the source hides
#                                    (Dan's sign off 2026-09-19, L324).
SKIP_DIRS = {".git", "SDKExplicitPrecompiledModules"}


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
