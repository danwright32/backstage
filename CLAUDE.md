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
- The repository is public while it is being built, for the Actions minutes, and goes private
  afterwards. Nothing in it may carry a secret in the meantime.
