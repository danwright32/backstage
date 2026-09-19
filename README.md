# backstage

Shared Swift packages for the performance tooling apps (Ovation, Overture, Downbeat).

The first of them is a Google sign in and Gmail sending package, extracted from
Overture's proven files rather than rewritten, tracked in the
`Shared Google sign in package` milestone and specified in ovation#39.

## The one rule worth reading before anything else

**The package carries no default scope list.** Every consumer names the OAuth
scopes it wants at its own call site, and a consumer that names none does not
compile. A default set means a consumer silently inherits whatever is in it, and
what would be in it here includes mailbox modify, which grants the ability to
alter and delete mail. An over broad permission is invisible, because the code
never attempts what it is not meant to do, while a missing one fails loudly on
the first run.

## What the package tells a consumer about its own health

Every response body this package could not decode is recorded with the endpoint
it came from and why, and `ResponseDecodeHealth.shared` is how a consumer reads
that back:

    for endpoint in ResponseDecodeHealth.shared.failing() {
        print(endpoint.endpoint, endpoint.consecutiveFailures, endpoint.lastReason ?? "")
    }

`current()` is every endpoint that has failed at least once, sorted by name.
`failing()` is the subset whose failures have reached `failingRun` in a row,
which is the condition the package judges by and is published so a consumer
wording a status line around it reads the same number.

**The package picks no surface for it.** Three apps share this, so a status
line, a log entry or an alert chosen here would be chosen for all three. What it
owes them is the fact and the threshold; what to do with it is each consumer's
decision.

## This repository is public on purpose, and temporarily

Actions is unlimited on a public repository. A private one on the Free plan gets
2,000 included minutes a month with macOS runners billing at ten times the rate.
It goes private once the build no longer needs the minutes, tracked as issue #6.

**So the privacy floor is load bearing rather than a formality.** Before any
push, `scripts/check-secrets.sh` refuses a Google client secret, a client id, an
access or refresh token, a real mailbox address or a credential store file
anywhere in the tree, names which rule fired, and never prints the value it
matched.

**And the history is read too, because deleting a secret from a public
repository does not remove it.** It stays readable in the history, in forks, and
in anything that cloned or cached it, so the case that matters most, a
credential that WAS committed and has since been tidied away, is the exact one a
working tree scan cannot see. `scripts/check-secrets-history.sh` reads every
blob reachable from every ref and applies the same rules, imported from
`scripts/lib/secret_rules.py` so the two guards cannot disagree about what a
secret is. It runs on every pull request, on a push to main, daily and on
demand, rather than in the push gate, because it is the one check whose cost
grows with the number of commits. The pull request run is the one that matters
most: a branch can hold a secret in one commit and remove it in the next, and
the squash that lands keeps neither, so that intermediate commit is read nowhere
else.

Its remedy is **rotation**, not rewriting history. Anything that was public has
been fetchable for as long as it was there.

**One value is one finding.** It walks the build output too, because a secret
can reach a build product by routes the source never shows, so a single source
line arrives as dozens of copies of itself. Occurrences of the same value in
files git does not track are counted against the tracked file that carries it
rather than listed one by one. A value found only in untracked files is still
reported in full: there, the build product is the only evidence there is.

## Working in it

    ./scripts/install-git-hooks.sh   # once per clone
    ./scripts/run-tests.sh           # everything
    ./scripts/check-secrets.sh .     # the privacy floor alone

`scripts/run-tests.sh` runs every `scripts/test-*.sh`, judges each by its exit
code, and refuses both a run that found no suites and a run in which a suite it
discovered did not execute.

## main is protected, so changes go through a pull request

CI runs the guard against the real tree and then the suite, on **ubuntu-latest
and macos-latest both**, and main requires both to pass. The macOS job is not
redundant: macOS ships bash 3.2 and Linux ships bash 5, and under `set -u` the
two disagree about expanding an empty array, which is a fault that has already
shipped here once. Each job prints the bash it ran, so an image quietly moving
to bash 5 on macOS removes that coverage loudly rather than silently.

The rule is **not** enforced for the repository owner, by Dan's decision of
2026-09-17: a branch frozen by a CI outage is worse here than an occasional
unchecked push, in a repository with one committer. Everyone else, and every
pull request, still needs both checks. To make it strict, and to lift it again:

    gh api -X POST repos/danwright32/backstage/branches/main/protection/enforce_admins
    gh api -X DELETE repos/danwright32/backstage/branches/main/protection/enforce_admins

**The two job names are load bearing.** They are what the branch rule names, and
a branch rule cannot be found by searching this repository. Renaming a job
without updating the rule leaves main requiring a check that no longer runs.
