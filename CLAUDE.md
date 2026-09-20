# backstage

Shared Swift packages for the performance tooling apps (Ovation, Overture and Downbeat). The first
is `BackstageGoogle`: Google sign in and Gmail sending, extracted from Overture's proven files
rather than rewritten.

`README.md` carries the rules that decide how the package is used. Read it before changing the
package's public surface.

## Where things are

- `Sources/BackstageGoogle/` is the package and `Tests/BackstageGoogleTests/` its suite.
- `Package.swift` declares the one library product and the one test target.
- `scripts/` holds the repository's helpers.

## Build and test

    swift build
    swift test

## What to know before editing

- macOS 14 or newer, and Swift tools 6.0. The platform floor is a property of the code rather than
  a preference: the sources import AppKit, to open the consent page in the person's browser, and
  Network, for the loopback listener that catches Google's redirect back. Neither exists on Linux,
  so this package cannot be built or tested there.
- The package carries no default scope list. Every consumer names the OAuth scopes it wants at its
  own call site, and a consumer that names none gets none. Adding a default here would grant scopes
  to three apps at once, silently.
- The repository is PRIVATE, since 2026-09-19 and issue #6. It was public for its whole build,
  for the Actions minutes, so everything in its history was public and is still out there
  whatever the current visibility says. Nothing in it may carry a secret, and that rule did not
  relax when the visibility changed: the two secrets guards, over the working tree and over every
  blob ever committed, stay exactly as they were.
- Branch protection on main is GONE, because protected branches on a private repository need
  GitHub Pro. Dan accepted that on 2026-09-19. CI still runs and the pre push hook still gates
  Dan's machine; nothing refuses a red pull request. Do not describe main as protected.
