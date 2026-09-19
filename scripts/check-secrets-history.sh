#!/usr/bin/env python3
''''exec python3 "$0" "$@" #'''
__doc__ = """Refuse if a credential or a real mailbox is in this repository's HISTORY.

backstage#11. scripts/check-secrets.sh reads the working tree. It reads only what
is there NOW, and this repository is PUBLIC for the whole build with a Google
OAuth client as its entire subject matter.

WHY THAT IS NOT ENOUGH HERE. Deleting a secret from a public repository does not
remove it: it stays readable in the history, in forks, and in anything that
cloned or cached it, for as long as the repository exists. So the one case where
the working tree guard matters most, a credential that WAS committed and has
since been tidied away, is the exact case it cannot see. The tree would be
clean, the guard would print "clean", and the secret would be a URL away. Going
private later does not fix it either, because anything already fetched is
already out.

THE SAME RULES, NOT A SECOND SET. What counts as a secret is decided once, in
scripts/lib/secret_rules.py, and both guards import it. Two guards each deciding
what a secret is are two rules that drift, and this one would drift toward
whichever shape somebody happened to test it on (L370).

WHAT IT NEVER PRINTS: the value it matched, exactly as the working tree guard
never does. Its output goes into CI logs and terminal scrollback, by a route no
file scanner inspects (L222).

THE REMEDY IN ITS MESSAGE IS ROTATION, not rewriting history. A secret that has
been public is compromised whatever happens to the commit afterwards, and a
message telling somebody to rewrite history would name an action that does not
change the state they are actually in (L111).

NOT ON EVERY PUSH. This is the one check whose cost grows with the number of
commits, so it runs on a schedule, on a push to main, and on demand, rather than
in the pre push hook.

THE LIMIT SAID OUT LOUD: `git rev-list --objects --all` walks every blob
reachable from every ref, local branches, tags and remote tracking refs
included. A blob reachable only from a reflog entry, from a stash, or from a
pull request ref that was never fetched is outside it, and is named here rather
than left for somebody to discover.
"""
import os
import subprocess
import sys

# THE RULES LIVE IN ONE PLACE, shared with the working tree guard (L370).
#
# IMPORTED, OR REFUSED. An ImportError that fell through would exit 1, and 1 is
# this script's code for "a secret was found", so a missing library would read as
# a finding rather than as a check that could not run (L11, L98).
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
try:
    from secret_rules import CREDENTIAL_FILENAMES, findings_in_bytes
except ImportError as error:
    print("REFUSED: scripts/lib/secret_rules.py could not be imported (%s)." % error)
    print("    The rules this guard applies live there, so nothing was checked.")
    sys.exit(2)

# A blob larger than this is not read. It is NAMED rather than skipped quietly,
# because a scanner that gives up on a file and says nothing reads as clean
# (L329, L98). Ten megabytes is far above anything this repository commits, so a
# blob over it is itself worth a look.
LARGEST_BLOB_READ = 10 * 1024 * 1024

# How many distinct blobs are placed in a commit before the run stops asking.
#
# backstage#42. Placing one is `git log --all --find-object`, a full walk of
# every commit in this repository, and it is asked once per blob. A clean run
# asks nothing, so the cost is never paid until the run that finds a lot, which
# is the run whose report matters most: with the job's timeout spent walking
# history, the run that found the most would say the least (L492).
#
# So the report comes out first and this is decoration, bounded, and it says how
# many it did not place rather than stopping quietly (L98). Overridable, so the
# suite can drive the bound without committing thirty secrets to a fixture; the
# default is the real one and a test asserts it.
LARGEST_PLACEMENT_RUN = 25


def git(repo, *arguments, **kwargs):
    """Ask git, with ITS OWN environment variables stripped.

    An inherited GIT_DIR BEATS the -C, and git exports GIT_DIR to its hooks, so
    every question would otherwise be answered by whatever GIT_DIR names rather
    than by the repository this was pointed at.
    """
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    return subprocess.run(["git", "-C", repo] + list(arguments),
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          env=environment, check=False, **kwargs)


def every_blob(repo):
    """Every blob reachable from every ref, as {sha: the path it was last seen at}.

    One blob can sit at several paths across history. The path is carried so a
    finding can be reported somewhere a person can look, and the commit below is
    what places it in time.
    """
    listed = git(repo, "rev-list", "--objects", "--all")
    if listed.returncode != 0:
        return None
    blobs = {}
    for line in listed.stdout.decode("utf-8", errors="replace").splitlines():
        sha, _, path = line.partition(" ")
        if not path:
            # A commit, a tag or the root tree: no path, and nothing to read.
            continue
        blobs[sha] = path
    if not blobs:
        return {}
    # rev-list lists trees as well as blobs. Ask what each object IS rather than
    # inferring it from having a path, which trees also have.
    kinds = git(repo, "cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)",
                input=("\n".join(blobs) + "\n").encode())
    if kinds.returncode != 0:
        return None
    sized = {}
    for line in kinds.stdout.decode("utf-8", errors="replace").splitlines():
        parts = line.split()
        if len(parts) != 3 or parts[1] != "blob":
            continue
        sized[parts[0]] = (blobs[parts[0]], int(parts[2]))
    return sized


def commit_holding(repo, sha, path):
    """A commit this blob appears in, and when, or None if it cannot be placed.

    Asked once per OFFENDING blob rather than for every blob in the repository,
    so a clean run asks nothing at all.
    """
    found = git(repo, "log", "--all", "--max-count=1", "--format=%h %ci",
                "--find-object=" + sha, "--", path)
    if found.returncode != 0:
        return None
    line = found.stdout.decode("utf-8", errors="replace").strip().splitlines()
    return line[0] if line else None


def place_each_blob(repo, findings, limit):
    """Say which commit each finding's blob sits in, AFTER the report is out.

    Decoration, never the report. Distinct blobs only, because several findings
    in one file share a blob and placing it twice is the same walk twice.
    """
    distinct = []
    for _rule, sha, path, _number in findings:
        if (sha, path) not in distinct:
            distinct.append((sha, path))

    print("    WHERE EACH ONE SITS. This is a full walk of the history per blob, so it")
    print("    comes after the report above rather than inside it.")
    for index, (sha, path) in enumerate(distinct):
        if index >= limit:
            remaining = len(distinct) - limit
            print("      %d further blob(s) were NOT placed. That is a bound on this"
                  % remaining)
            print("      decoration, not on the findings: every one of them is listed above.")
            print("      Place one by hand with:")
            print("          git log --all --find-object=<blob> -- <path>")
            return
        placed = commit_holding(repo, sha, path)
        print("      blob %s at %s: %s"
              % (sha[:8], path, "commit " + placed if placed
                 else "no commit could be found holding it"))


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else "."
    if not os.path.isdir(repo):
        print("REFUSED: %s is not a directory that can be read, so nothing was checked." % repo)
        return 2

    inside = git(repo, "rev-parse", "--is-inside-work-tree")
    if inside.returncode != 0:
        print("REFUSED: %s is not a git checkout, so it has no history to read." % repo)
        print("    This is the one check that reads history. It cannot be answered here.")
        return 2

    blobs = every_blob(repo)
    if blobs is None:
        print("REFUSED: %s could not be asked what it holds, so nothing was checked." % repo)
        return 2

    # NOTHING TO EXAMINE IS NOT A PASS (L98). A repository with no commits yet,
    # or one whose refs could not be walked, must never read as a clean history.
    if not blobs:
        print("REFUSED: %s holds no committed blob, so nothing was checked." % repo)
        print("    A history with nothing in it is not a history that came back clean.")
        return 2

    examined = 0
    unread = []
    findings = []
    for sha, (path, size) in sorted(blobs.items(), key=lambda item: item[1][0]):
        if size > LARGEST_BLOB_READ:
            # SAID, NOT SKIPPED QUIETLY. A blob nothing looked at is not a blob
            # that came back clean.
            unread.append((sha, path, size))
            continue
        content = git(repo, "cat-file", "blob", sha)
        if content.returncode != 0:
            unread.append((sha, path, -1))
            continue
        examined += 1
        if CREDENTIAL_FILENAMES.search(os.path.basename(path)):
            findings.append(("credential-store", sha, path, 0))
        for rule, number, _value in findings_in_bytes(content.stdout):
            findings.append((rule, sha, path, number))

    if examined == 0:
        print("REFUSED: read 0 of the %d blob(s) in %s, so nothing was checked."
              % (len(blobs), repo))
        return 2

    for sha, path, size in unread:
        print("NOT READ: %s at %s (%s)"
              % (sha[:8], path, "%d bytes" % size if size >= 0 else "could not be read"))
        print("    It was not examined, which is not the same as it being clean.")

    if findings:
        print("REFUSED: %d finding(s) in this repository's HISTORY. The value itself is"
              % len(findings))
        print("    never printed. These are blobs that are still reachable, whatever the")
        print("    working tree looks like now.")
        # EVERYTHING FOUND, AND THE REMEDY, BEFORE ANYTHING IS LOOKED UP. Both
        # are computed already; the placement below is not (L492).
        ordered = sorted(findings, key=lambda f: (f[2], f[3], f[0]))
        for rule, sha, path, number in ordered:
            where = "%s line %d" % (path, number) if number else path
            print("  RULE %-22s %s   blob %s" % (rule, where, sha[:8]))
        print("")
        print("    THE REMEDY IS TO ROTATE THE CREDENTIAL, not to rewrite this history.")
        print("    Anything that was public has been fetchable by anyone for as long as it")
        print("    was there, and by forks and caches afterwards. Revoke it at Google,")
        print("    issue a new one, and keep the new one out of this repository.")
        print("")

        limit = LARGEST_PLACEMENT_RUN
        override = os.environ.get("BACKSTAGE_PLACEMENT_LIMIT")
        if override and override.isdigit():
            limit = int(override)
        place_each_blob(repo, ordered, limit)
        return 1

    print("clean: read %d of %d committed blob(s), %d not read, 0 findings."
          % (examined, len(blobs), len(unread)))
    return 1 if unread else 0


if __name__ == "__main__":
    sys.exit(main())
