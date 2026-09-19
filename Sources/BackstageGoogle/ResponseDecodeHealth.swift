// How each endpoint is decoding, as something a consumer can READ (backstage#12).
//
// ResponseBody records every response body it could not decode into
// ResponseDecodeFailures, with the endpoint and a reason, and nothing in this
// package read it. Stored data needs a reader, not just a writer (L46): as it
// stood, the recording was real work producing a record with no consumer, which
// is the shape that reads as observability and provides none. A run of
// unreadable token responses would have filled that register in silence.
//
// THIS PACKAGE DOES NOT PICK THE SURFACE, and that is the whole reason this file
// is a reading rather than a status line, a log call or an alert. Three apps
// share it, and a package that picks the surface picks it for all three. What it
// owes them is the fact and the threshold it judges by; whether that becomes a
// status line, a log entry or an alert is each consumer's decision.
//
// WRITTEN HERE RATHER THAN BY MAKING ResponseBody PUBLIC. That file is ported
// from Overture and carries a fix rather than a convenience, so it is held
// byte for byte against its origin. Widening its declarations would be an edit
// to a copy, which is the thing every ported header in this repository forbids
// (L263). The register stays internal and this is the face it shows outward.

import Foundation

// How ONE endpoint is behaving. A value type, so what a consumer holds is a
// reading taken at a moment rather than a live view of a register another thread
// is writing into.
public struct EndpointDecodeHealth: Equatable, Sendable {

    // The endpoint as the call site named it.
    public let endpoint: String

    // Every response body read from it, decoded or not.
    public let attempts: Int

    // How many of those could not be decoded, across the whole session. Kept
    // across a recovery, because this is what says the endpoint has been
    // unhealthy today, which a cleared count could not (L160).
    public let failures: Int

    // How many have failed in a row RIGHT NOW. The run ends on a success and on
    // nothing else: no amount of elapsed time is evidence that something works
    // again.
    public let consecutiveFailures: Int

    // Why the last one could not be read, in words. A count with no reason
    // cannot be acted on, and the reason is what separates Google answering
    // badly from this package asking for a field that moved (L148).
    public let lastReason: String?

    // Whether the run has reached the threshold below. Exposed as well as the
    // two numbers it is derived from, so every consumer asks the question the
    // same way rather than each writing its own comparison (L41).
    public var isFailing: Bool { consecutiveFailures >= ResponseDecodeHealth.failingRun }
}

// The readable face of the decode register.
//
// `shared` reads the register this package's own calls record into, which is the
// one a consumer wants. The initialiser taking a register is internal, and
// exists so a test drives its own rather than the one every other test is using
// (L2).
public struct ResponseDecodeHealth: Sendable {

    // THE CONDITION IS A RUN OF FAILURES, not a proportion, and the number is
    // published because a consumer wording "2 of 3" around it is making a claim
    // about what this package does. It is read from the register's own constant
    // rather than written again here, so the two cannot drift (L41).
    public static var failingRun: Int { ResponseDecodeFailures.failingRun }

    public static let shared = ResponseDecodeHealth(register: .shared)

    private let register: ResponseDecodeFailures

    init(register: ResponseDecodeFailures) {
        self.register = register
    }

    // Every endpoint that has failed at least once, sorted by name so a surface
    // polling this is stable between reads rather than reshuffling.
    //
    // A FUNCTION RATHER THAN A PROPERTY, deliberately. Each call takes the
    // register's lock and copies what it holds, and a computed property reads at
    // the call site as a free field access, which is how a whole collection gets
    // re-derived on every pass of a render body (L383).
    public func current() -> [EndpointDecodeHealth] {
        register.current().map(Self.reading(of:))
    }

    // Only those whose run has reached the threshold. A consumer wanting to act
    // rather than display reads this one.
    public func failing() -> [EndpointDecodeHealth] {
        register.failing().map(Self.reading(of:))
    }

    private static func reading(of health: ResponseDecodeFailures.Health) -> EndpointDecodeHealth {
        EndpointDecodeHealth(endpoint: health.endpoint,
                             attempts: health.attempts,
                             failures: health.failures,
                             consecutiveFailures: health.consecutiveFailures,
                             lastReason: health.lastReason)
    }
}
