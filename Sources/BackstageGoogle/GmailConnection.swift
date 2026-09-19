// Ported-From: danwright32/overture mac/Overture/Integration/GmailConnection.swift @ 0bb3869c8f71777d08712e9fa146fd07c6da699f
//
// Ported on 2026-09-19 by backstage#2. Do not edit this copy to fix a fault that is also in
// the origin: fix it there and re-port (L263).
//
// ONE DELIBERATE CHANGE: no `shared` instance and no default loader. The origin's default read its
// own app's token file, which a package cannot know. Each consumer constructs one and says how
// connectedness is read, typically `{ GmailCredentials.isConnected(tokensAt: itsOwnURL) }`.
import Foundation
import Observation

// #1770: the ONE cached answer to "is Gmail connected?".
//
// This used to be `GmailAuthManager.shared.isConnected`, which resolves to GmailCredentials.isConnected,
// which opens the token file and JSON-decodes it. That is a synchronous filesystem read, and it was being
// made inside SwiftUI view bodies: once per queue card, plus once for the pill strip, plus once per access
// of a FollowUpsView computed property. The queue re-renders on every scroll movement, so the same answer
// was re-read from disk for every visible card on every frame. It is one fact about the app, identical for
// every card, and it changes only at moments the app already knows about.
//
// @Observable, so the surfaces reading it re-render when it actually changes rather than because they
// happened to be rebuilt. Refreshed at the transitions in `refresh()`'s call sites: launch (this init), a
// completed OAuth connect, the Debug seed, the periodic reply check, and a send that failed, which is the
// moment a revoked token shows itself. A cached credential that has gone stale is the failure this design
// could introduce, so it is the one GmailConnectionTests pins hardest.
@MainActor
@Observable
public final class GmailConnection {
    private let load: @MainActor () -> Bool

    public private(set) var isConnected: Bool

    public init(load: @escaping @MainActor () -> Bool) {
        self.load = load
        self.isConnected = load()
    }

    // Go back to the source. Callers are the state transitions above, never a render path: the whole
    // point of this type is that drawing a card asks the filesystem nothing.
    public func refresh() {
        isConnected = load()
    }

    // Refresh and answer in one step, for a caller that must not act on a cached value (a send failing,
    // a background check about to skip). Deliberately NOT the default read: it costs a disk hit.
    @discardableResult
    public func refreshedIsConnected() -> Bool {
        refresh()
        return isConnected
    }
}
