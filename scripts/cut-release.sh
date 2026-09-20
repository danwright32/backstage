#!/usr/bin/env python3
''''exec python3 "$0" "$@" #'''
__doc__ = """Tag a release, and refuse one that anything at that commit has not judged green.

backstage#12, ovation#423. Other repositories pin to a tag, so a tag is a
durable, publicised pointer into this history. Ovation takes an exact version of
this package, which means whatever this names is what Ovation compiles for as
long as that pin stands.

WHY A SCRIPT RATHER THAN `gh release create`. Everything below is a check
somebody doing it by hand would have to remember, and the one that matters is
the one nobody does: reading the conclusions AT THE COMMIT BEING TAGGED rather
than at whatever the branch happens to point at now.

THE TARGET IS RESOLVED FROM THE REMOTE, NEVER FROM LOCAL main. A local tracking
ref is a copy of something that lives elsewhere and reads identically to the
source, so a checkout that has not fetched tags a commit that is not the tip
while reporting the tip's name (L454). `git ls-remote` asks the server.

THE CHECKS ARE READ AT THAT SHA, BY SHA. A superseded run reports under the same
check names and answers for the wrong revision in both directions (L179, L458),
and a version other repositories pin to is the worst place for a stale green.
So this asks the commit, not the branch and not the pull request.

IT FAILS CLOSED ON "NOTHING TO READ". A commit with no check runs at all is not
a commit that passed: it is one nothing has judged, which is what an empty
answer from a watcher looks like when it is working correctly and when it is
broken alike (L98). Zero checks is a refusal with its own message.

EVERY WORKFLOW IN THE TREE MUST HAVE ANSWERED. Branch protection cannot be read
on a private repository without Pro, so "required checks" is not a list this can
fetch. It derives the expectation from the workflows committed AT THAT SHA
instead, which is the same revision being judged, rather than from the checkout
it runs in (L398). A workflow present in the tree with no run at that commit is
a refusal naming it.

THE HISTORY SCAN RUNS AND ITS RESULT GOES ON THE RELEASE. This repository's
entire subject is a Google OAuth client, and a release is a new, durable,
publicised pointer at its history (L489). The scan's own output is recorded on
the release so the claim carries its measurement rather than a sentence about
one (L316).

NOT 1.0.0, AND THAT IS A DECISION. backstage#12 and backstage#15 are open
questions about this package's public surface, and a 1.0 freezes an API that is
explicitly mid decision.

WHAT IT DOES NOT DO: it never pushes a commit, never moves a branch, and never
deletes or moves an existing tag. A tag that exists already is a refusal, because
moving one silently changes what every pinned consumer compiles.
"""

import json
import os
import re
import subprocess
import sys

REPO = os.environ.get("BACKSTAGE_RELEASE_REPO") or "danwright32/backstage"
HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.environ.get("BACKSTAGE_REPO_ROOT") or os.path.dirname(HERE)

# The seam every test drives. Each entry is a shell command; the default set
# talks to the real remote and the real API, so nothing that does not ask for
# the seam can reach a fixture (ovation#214, L2).
FAKE = os.environ.get("BACKSTAGE_RELEASE_FAKE_DIR")

# A tag this repository will accept. backstage#12: 0.x while the surface is open.
TAG_SHAPE = re.compile(r"^0\.\d+\.\d+$")


def run(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def faked(name):
    """The recorded answer for one step, where a suite has planted one."""
    if not FAKE:
        return None
    path = os.path.join(FAKE, name)
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def resolve_head():
    """The remote's main, asked of the server rather than read from a local ref."""
    recorded = faked("ls-remote")
    if recorded is not None:
        text = recorded
    else:
        result = run(["git", "ls-remote", "origin", "refs/heads/main"])
        if result.returncode != 0:
            return None, "could not reach the remote to resolve main"
        text = result.stdout
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == "refs/heads/main":
            return parts[0], None
    return None, "the remote did not name refs/heads/main"


def check_runs(sha):
    recorded = faked("check-runs")
    if recorded is not None:
        text = recorded
    else:
        result = run(["gh", "api", f"repos/{REPO}/commits/{sha}/check-runs",
                      "--jq", '.check_runs[] | "\\(.name)\\t\\(.status)\\t\\(.conclusion)"'])
        if result.returncode != 0:
            return None, "could not read the check runs at that commit"
        text = result.stdout
    runs = []
    for line in text.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            return None, f"a check run could not be read: {line!r}"
        runs.append({"name": parts[0], "status": parts[1], "conclusion": parts[2]})
    return runs, None


def workflow_job_names(sha):
    """The job names every committed workflow declares, AT THAT SHA."""
    recorded = faked("workflows")
    if recorded is not None:
        return [n for n in recorded.splitlines() if n.strip()], None
    listing = run(["git", "ls-tree", "-r", "--name-only", sha, ".github/workflows/"],
                  cwd=REPO_ROOT)
    if listing.returncode != 0:
        return None, "could not list the workflows at that commit"
    names = []
    for path in listing.stdout.splitlines():
        if not path.strip():
            continue
        shown = run(["git", "show", f"{sha}:{path}"], cwd=REPO_ROOT)
        if shown.returncode != 0:
            return None, f"could not read {path} at that commit"
        # A job's `name:` is indented under it; the workflow's own is column one.
        for line in shown.stdout.splitlines():
            match = re.match(r"^\s+name:\s*(.+?)\s*$", line)
            if match:
                names.append(match.group(1).strip().strip('"').strip("'"))
    return names, None


def tag_exists(tag):
    recorded = faked("ls-remote-tags")
    if recorded is not None:
        return f"refs/tags/{tag}" in recorded
    result = run(["git", "ls-remote", "--tags", "origin", f"refs/tags/{tag}"])
    return result.returncode == 0 and f"refs/tags/{tag}" in result.stdout


def refuse(lines):
    print("REFUSED: " + lines[0])
    for line in lines[1:]:
        print("         " + line)
    return 1


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print("Usage: scripts/cut-release.sh <tag> [--sha <sha>] [--dry-run]")
        print("       The tag is 0.x.y while the public surface is open (backstage#12).")
        return 2

    tag = argv[0]
    dry_run = "--dry-run" in argv
    explicit = None
    if "--sha" in argv:
        index = argv.index("--sha")
        if index + 1 >= len(argv):
            return refuse(["--sha was given with no commit after it."])
        explicit = argv[index + 1]

    if not TAG_SHAPE.match(tag):
        return refuse([
            f"{tag!r} is not a shape this repository releases.",
            "backstage#12 and backstage#15 are open questions about the public",
            "surface, so the version stays 0.x until they are answered: a 1.0",
            "freezes an API that is explicitly mid decision.",
        ])

    if tag_exists(tag):
        return refuse([
            f"the tag {tag} already exists on the remote.",
            "Moving a tag silently changes what every pinned consumer compiles,",
            "so this never moves one. Pick the next version.",
        ])

    sha, problem = (explicit, None) if explicit else resolve_head()
    if problem:
        return refuse([problem, "Nothing was tagged."])

    runs, problem = check_runs(sha)
    if problem:
        return refuse([problem, f"Nothing was tagged. The commit was {sha}."])

    # ZERO IS A REFUSAL, not a pass. A commit nothing has judged reports exactly
    # what a commit that passed everything reports, if the answer is read as a
    # list of failures (L98).
    if not runs:
        return refuse([
            f"no check has run at {sha[:12]} at all, so nothing has judged it.",
            "That is not a pass. Push the commit, wait for CI, and run again.",
        ])

    unfinished = [r for r in runs if r["status"] != "completed"]
    failed = [r for r in runs if r["status"] == "completed" and r["conclusion"] != "success"]
    if unfinished or failed:
        lines = [f"the checks at {sha[:12]} are not all green, so it is not releasable."]
        for r in unfinished:
            lines.append(f"still running: {r['name']}")
        for r in failed:
            lines.append(f"{r['conclusion']}: {r['name']}")
        return refuse(lines)

    declared, problem = workflow_job_names(sha)
    if problem:
        return refuse([problem, f"Nothing was tagged. The commit was {sha}."])
    if not declared:
        return refuse([
            f"no workflow could be read at {sha[:12]}, so what SHOULD have run is unknown.",
            "A green list of nothing is not evidence. Nothing was tagged.",
        ])
    answered = {r["name"] for r in runs}
    # A matrix job's name carries its axis, so a declared name is matched as a
    # prefix of what actually ran rather than by equality.
    missing = [name for name in declared
               if not any(a == name or a.startswith(name.split("${{")[0].strip())
                          for a in answered)]
    if missing:
        lines = [f"a workflow committed at {sha[:12]} has no run at that commit."]
        for name in missing:
            lines.append(f"declared, never ran: {name}")
        lines.append("A check that did not run cannot have passed. Nothing was tagged.")
        return refuse(lines)

    history = faked("secrets-history")
    if history is None:
        scan = run(["bash", os.path.join(HERE, "check-secrets-history.sh")], cwd=REPO_ROOT)
        if scan.returncode != 0:
            return refuse([
                "the history scan did not come back clean, so nothing was tagged.",
                *scan.stdout.strip().splitlines()[-4:],
            ])
        history = scan.stdout.strip()

    notes = "\n".join([
        f"Commit: {sha}",
        "",
        "Every workflow committed at this commit ran at it, and every check run",
        "at it concluded success:",
        *[f"  {r['name']}: {r['conclusion']}" for r in sorted(runs, key=lambda r: r["name"])],
        "",
        "Secret history scan at this commit:",
        f"  {history.splitlines()[-1] if history else '(no output)'}",
        "",
        "0.x while backstage#12 and backstage#15 are open: the public surface is",
        "mid decision and a 1.0 would freeze it.",
    ])

    if dry_run:
        print(f"WOULD TAG {tag} at {sha}")
        print(notes)
        return 0

    created = run(["gh", "release", "create", tag, "--repo", REPO,
                   "--target", sha, "--title", tag, "--notes", notes])
    if created.returncode != 0:
        print("FAILED: the release was not created.")
        print(created.stderr.strip())
        return 1

    print(f"RELEASED {tag} at {sha}")
    print(created.stdout.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
