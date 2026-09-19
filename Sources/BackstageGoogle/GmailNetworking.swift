// Ported-From: danwright32/overture mac/Overture/Integration/GmailNetworking.swift @ 0bb3869c8f71777d08712e9fa146fd07c6da699f
//
// Ported on 2026-09-19 by backstage#2. Do not edit this copy to fix a fault that is also in
// the origin: fix it there and re-port (L263).
//
// TAKEN WHOLE AND UNCHANGED. Internal: no consumer needs to name it.
import Foundation

// #468 (SUP-004): a single, bounded URLSession every Gmail call routes through by default. The
// plain URLSession.shared this replaced has a 7-day resource timeout, so a stalled call (token
// refresh, send, reply check) could hang for days with no recovery short of an app restart. Every
// call site here still injects its own fetch closure for tests, so this only changes what a real
// production call actually waits on.
enum GmailNetworking {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()
}
