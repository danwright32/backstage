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

## This repository is public on purpose, and temporarily

Actions is unlimited on a public repository. A private one on the Free plan gets
2,000 included minutes a month with macOS runners billing at ten times the rate.
It goes private once the build no longer needs the minutes, tracked as issue #6.

**So the privacy floor is load bearing rather than a formality.** Before any
push, `scripts/check-secrets.sh` refuses a Google client secret, a client id, an
access or refresh token, a real mailbox address or a credential store file
anywhere in the tree, names which rule fired, and never prints the value it
matched.

## Working in it

    ./scripts/install-git-hooks.sh   # once per clone
    ./scripts/run-tests.sh           # everything
    ./scripts/check-secrets.sh .     # the privacy floor alone

`scripts/run-tests.sh` runs every `scripts/test-*.sh`, judges each by its exit
code, and refuses both a run that found no suites and a run in which a suite it
discovered did not execute.
