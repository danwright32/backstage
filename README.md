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

## Connected means these scopes, and says who and when

`GmailAuthManager.connection` answers with a grant rather than a yes or no:

    case notConnected
    case connected(GmailGrant)                                    // account, scopes, obtained, last confirmed
    case grantMismatch(missingScopes: [String], storedAccount: String?)

The scopes a token was granted for are recorded with it, and connected is judged
against **this consumer's own** scope list. That is the one fact that differs
between three apps sharing this package, so without it a token written by one is
adopted by another and fails at the first call needing a scope it never had.
Coverage, not equality: a wider stored grant still covers a narrower want.

A token recording no grant at all is **not** connected. It cannot be shown to
cover anything, so the person re-consents.

The account is nil unless an identity scope was requested, which for a consumer
asking only to send is always. That absence is recorded as honestly as a value
would be, rather than left looking like a gap.

`lastConfirmedAt` moves only on a successful exchange, because that is the only
evidence the grant is still live. With an OAuth client in Testing status the
refresh token expires every seven days, and a dead local copy otherwise reads
exactly like a live one.

## An outgoing mail can carry attachments, and the refusal is on the request

`OutgoingMail.attachments` is a list of `MailAttachment`, empty by default. A
`MailAttachment` needs all three of a filename, a content type and some bytes,
and its init is failable, so an empty file or an unnamed one cannot be
constructed at all rather than reaching somebody's inbox as a document that will
not open. The content type is validated as one type and one subtype: it lands in
a MIME header, so a type carrying a semicolon would add a parameter to that
header and one carrying a line break would add a header.

**The message form is chosen from two places, so there are four of them.** The
sender's signature decides whether there is a `text/html` part; the mail decides
whether there are attachments; the two are independent.

|                 | no attachment           | attachment                              |
|-----------------|-------------------------|-----------------------------------------|
| plain signature | one `text/plain` part   | `multipart/mixed`                       |
| HTML signature  | `multipart/alternative` | `multipart/mixed` wrapping that alternative |

Written as "become mixed when there is an attachment", the fourth cell loses its
HTML part or ends the outer multipart with the inner one's closing delimiter. So
the readable text of a message is built once, as a MIME entity that is the same
whether it is the whole message or the first part inside a mixed, and there is a
round trip test per cell that decodes what was produced rather than matching the
string the same change just wrote.

**The size refusal is measured on the encoded request, never on the file.** The
package sends at most 5 MB of request, and an attachment grows by roughly four
fifths on the way there: base64 into its own part, wrapped
at 76, then the whole message base64url encoded into `raw`, then JSON escaped. A
guard written against the file's own byte count admits a 3 MB PDF that arrives as
5.4 MB and gets exactly the opaque 400 the guard exists to prevent, while reading
as protection. `GmailSendError.tooLarge` carries both numbers, and the sentence a
consumer can show says why they differ, because otherwise it accuses a 5 MB file
of being 9 MB.

**A consumer can ask whether a mail fits before anybody presses send.**
`MailSender.measure(_:)` answers with a `MailSizeMeasurement` carrying the
encoded size, the limit and whether it fits, with no network call and without
asking for a token, so it costs nothing to call every time somebody attaches a
file. It is on the protocol rather than only on `GmailSender`, because a consumer
holding the seam is the one that needs it. `NotConfiguredSender` refuses to
measure exactly as it refuses to send: a sender that cannot send cannot say
whether something would go through it.

The number it reports is read off the same request body the send posts, so a
screen cannot say a file fits while the send says it does not.

`GmailSendLimits.maxRequestBytes` is a conservative floor rather than a
documented limit, and the constant's own comment says so. Google's reference for
`users.messages.send` was read on 2026-09-21 and states no maximum at all; 5 MB
is the figure issue #51 recorded, and the uploads guide beside it gives 5 MB only
as advice about when a simple upload is the right shape. Nothing here has
measured where Gmail actually starts refusing. It is 5,000,000 rather than
5 x 1024 x 1024 for the same reason: of the two errors, only refusing slightly
early is one a person can act on.

## The loopback listener is public, and the port is the consumer's choice

`LoopbackListener` is the local server that catches Google's redirect back to the
app. It is public because it has two consumers with different needs, and it was
internal until backstage#60, which is why Downbeat carried a copy of it that
lacked both of this one's hard won fixes.

    let (listener, port) = try await LoopbackListener.start(
        queue: myQueue,
        port: 8765,          // or nil to let the OS assign one
        onConnection: { connection in ... }
    )

**`port: nil` is the OS assigning one**, which is what a consumer wants when it
builds its redirect URI from the port that came back. **Naming a port** is what a
consumer wants when it registered a fixed redirect URI and therefore has to build
that URI before anything is bound. Neither is the right default for the other, so
it is a parameter.

Whichever is chosen, the bind is pinned to the IPv4 loopback. That is not
tidiness: without it `NWListener` can bind IPv6, and Google redirects the browser
to `http://127.0.0.1`, so the redirect never arrives and the sign in hangs with
nothing to say (#51).

**A bind refused with an address already in use is retried, on a named port too.**
The opposite was implemented first and measured wrong. A named port has two causes
for that code, another process holding it and a socket that has not finished
letting go, they cannot be told apart from the code, and the second is the common
one: it is what happens when somebody presses Connect, closes the window and
presses Connect again. The three attempts cost a fraction of a second and rescue
that case. When they are all spent the refusal says so in its own words, so a port
genuinely held by something else still reads as that rather than as a generic
failure.

## The redirect catch is shared too, and the tab says only what is true

`LoopbackListener` is the bind. `GoogleRedirectCatcher` is everything that makes
the bind useful: it waits for Google's redirect, reads the request line, answers
the browser, matches the state, and hands back the code or a typed reason there
is none.

    let catcher = GoogleRedirectCatcher(productName: "Ovation",
                                        expectedState: state,
                                        port: nil,            // or 8765
                                        queue: myQueue)
    let port = try await catcher.start()
    // build the redirect URI from that port, open the consent page
    let code = try await catcher.awaitCode(timeout: 90)

**What differs per consumer is an input**: the product name the tab is sent back
to, the state to match, and the port. Everything else is one rule in one place.
All four behaviours lived inside `GmailAuthManager` until backstage#61, which is
why Downbeat carried its own copy of all four and the two spellings had already
drifted apart. `GmailAuthManager` consumes this, so there is one implementation
rather than a shared one beside the old one.

**The state is required, and there is no way to ask for the match to be
skipped.** It is the only thing standing between this port and a code somebody
else put there, so a consumer that does not send one yet starts sending one.

**The tab says only what is true when it is shown, and says which of the three
things happened.** The page is written the moment the redirect lands, before the
token exchange and before the save, either of which can still fail, so it never
says the account is connected. The two copies disagreed in opposite directions
and both had a point: this one was right that the page must not overclaim, and
Downbeat's was right that somebody who was refused should read Google's own
reason in the tab they are already looking at. Both hold now.

**What Google said is escaped, not rendered.** Anything on this machine can open
`http://127.0.0.1:<port>/?error=whatever`, so the reason quoted back in the page
is written by whoever opened it. It is HTML escaped, and so is the product name.

**Each way the catch can end is its own answer**: `refusedByGoogle(reason)`,
`noCode`, `stateMismatch`, `timedOut`, `alreadyWaiting`. Google refusing consent
used to arrive as "no code in redirect", which is what a malformed redirect says
too, so the one thing a person needed in order to know whether trying again
would help was the one thing discarded.

**A consumer can end the wait with a reason of its own.** `abandon(reason:)`
exists because the Gmail flow re-probes its listener while waiting and is the
only thing that can see it die. Without it, the only way to report a dead
listener would be to wait out the give-up window that fast failure exists to cut
short.

**An answer that arrives before anybody waits is kept, not lost.** The redirect
can land between the bind returning and the wait starting. A catch that forgot
that would leave the wait hanging for ever, which cannot be told from slowness
and holds the port while it does.

**`GmailAuthManager` takes a `productName`, required rather than defaulted**, for
the same reason the scope list has no default: the page has to say where to go
back to, three apps share this, and the only default available is "the app",
which is every app.


## A test can never change a real Google login

A credential write or delete inside a test run must target a **throwaway** path,
defaulting to the system temporary directory. `saveTokens` and `clearTokens`
throw rather than proceeding, and `disconnect()` and `signalAuthExpired()` throw
with them.

This is separate from the refusal on live Gmail calls, and it has to be: that one
covers the way in, and these are the way out. A test reaching `disconnect()` on a
manager pointed at a real credentials directory would delete a real refresh
token, and there is no undo. The refusal lives in the package rather than in each
consumer's call site, because the write happens below that call site and no
consumer can fix it from outside.

Whether this is a test run is deliberately not a parameter, so a caller cannot
pass one word and bypass a control that exists to protect them.

**The package picks no surface for it.** Three apps share this, so a status
line, a log entry or an alert chosen here would be chosen for all three. What it
owes them is the fact and the threshold; what to do with it is each consumer's
decision.

## This repository is private, and was public for its whole build

It went private on 2026-09-19 (issue #6), once nothing depended on it being
public. Actions is unlimited on a public repository; a private one on the Free
plan gets 2,000 included minutes a month with macOS runners billing at ten times
the rate. Measured before the change: about 22 billed minutes per CI run, so
roughly 90 runs a month, plus about 30 for the daily history scan.

**Going private removed nothing that was already out, and the privacy floor is
load bearing because of that rather than in spite of it.** Every commit made
while it was public was fetchable by anyone for as long as it stood, and by
forks and caches afterwards. Nothing about the current visibility changes that,
which is exactly why the history scan below exists and why it stays.

**Branch protection is gone, and that is a known gap rather than an oversight.**
Protected branches on a private repository need GitHub Pro, so the two required
checks stopped gating anything the moment the repository was flipped. Dan's
decision, 2026-09-19: accept it. The pre push hook on his machine runs the same
suites CI runs, before anything leaves the machine, and there is one committer.
What is genuinely lost is that a red pull request can now be merged, because
nothing refuses it. Making the repository public again restores the rule exactly
as it was; so would GitHub Pro.

**The privacy floor itself.** Before any
push, `scripts/check-secrets.sh` refuses a Google client secret, a client id, an
access or refresh token, a real mailbox address or a credential store file
anywhere in the tree, names which rule fired, and never prints the value it
matched.

**And the history is read too, because deleting a secret from a repository that
was public does not remove it.** It stays readable in the history, in forks, and
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

**An address among bytes that are not text is not an address.** The mailbox rule
is the only one loose enough for random bytes to satisfy, since every credential
rule needs a documented prefix and a run of twenty or more characters. So it
stands down on content that holds a NUL byte or does not decode as UTF-8, which
is git's own test for a binary file. The credential rules still read every byte
of everything.

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

## Ported files, and what happens when one is edited here

Files taken from Ovation and Overture carry a `Ported-From` header naming the
repository, the path and the commit they came from.
`scripts/check-ported-artifacts.sh` asserts that commit is still on the origin's
main. `scripts/check-ported-content.sh` asserts the copy itself has not changed,
which is a different question and the one the headers were asking all along
when they said "do not edit this copy".

Four outcomes, because the real population has four:

- **in step**, the origin's file with one block of comments inserted. Nothing to
  record: the origin and the commit pin it.
- **adapted**, deliberately changed when it was ported, with the header saying
  how and a `Ported-Adapted` digest saying what it looked like then. Most of them
  are in this state, because the origin is one app's code and this is a package
  three apps share.
- **diverged**, an adaptation carrying a fix that is still pending at the origin,
  named by a `Ported-Divergence` issue that must still be OPEN. Closing that
  issue turns the file red until it is re-ported, which is the point: an
  authorisation that outlives its reason is not an authorisation.
- **drifted**, anything else, which is refused. The refusal prints the exact line
  to write if the change was meant.

Editing a ported file, including its comments, changes its digest. That is the
point: the re-record is a one-line diff somebody has to look at.

## main is no longer protected, and CI still runs

CI runs the guard against the real tree and then the suite, on **ubuntu-latest
and macos-latest both**. Until 2026-09-19 main REQUIRED both to pass; going
private on the Free plan removed that, as recorded above. They still run on
every pull request and on every push to main, and they are still the thing to
read before merging: what changed is that nothing now refuses a merge when they
are red. The macOS job is not
redundant: macOS ships bash 3.2 and Linux ships bash 5, and under `set -u` the
two disagree about expanding an empty array, which is a fault that has already
shipped here once. Each job prints the bash it ran, so an image quietly moving
to bash 5 on macOS removes that coverage loudly rather than silently.

The rule had already been lifted for the repository owner, by Dan's decision of
2026-09-17: a branch frozen by a CI outage is worse here than an occasional
unchecked push, in a repository with one committer. So what going private removed
was the rule as it applied to pull requests, which is the part that was doing the
work.

**The two job names were load bearing and are worth keeping stable anyway.** They
are what a branch rule names, and a branch rule cannot be found by searching this
repository, so a rename now would be silently fine and silently wrong again the
day protection comes back.
