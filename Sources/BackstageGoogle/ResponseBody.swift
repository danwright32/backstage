// Ported-From: danwright32/overture mac/Overture/Domain/ResponseBody.swift @ 750464734bffc8bd0af69898b13ec3e42d233c02
//
// Ported on 2026-09-18 by backstage#2. Do not edit this copy to fix a fault
// that is also in the origin: fix it there and re-port (L263).
//
// TAKEN WHOLE AND UNCHANGED, and it is here because it carries a FIX rather than
// a convenience. Its own note records eighteen reads of live responses that
// discarded the error with a `try?`, so a 200 whose body did not decode became
// no reply, no bounce (a pitch that bounced reading as delivered) and an empty
// calendar. GoogleOAuth.interpretRefreshResponse is one of those reads.
//
// INTERNAL, not public: no consumer of this package needs to name it.

import Foundation

// Reading the body of a response that ARRIVED, with "I could not understand this" kept apart from
// "there was nothing in it" (#2888).
//
// #2879 did this for the handoff FILES and its derived guard named this second set of sites without
// covering them, because the remedy differs (L129). A file sits on disk and can be re-read; a response
// is gone the moment it is discarded. Until this, eighteen reads of live responses discarded the error
// with a `try?`, so a 200 whose body did not decode became: no reply (`ReplyDetection`), no bounce
// (`BounceDetection`, so a pitch that bounced reads as delivered) and a calendar with no listings
// (`AlgoliaCalendar`, `SquarespaceCalendar`). An HTTP status failure was already handled at most of
// those sites. A 200 with an unreadable body was not.
//
// THE CALLER'S BEHAVIOUR IS UNCHANGED, deliberately, and that is the same decision #2879 made. Several
// of these reads are correctly best effort: a reply poll that cannot read one response must go on to
// the next one rather than throwing, and a signature fetch that fails must not stop a send. Making each
// caller plumb a failure somewhere would have meant either changing behaviour that is right, or leaving
// most of them silent, which is the defect rather than a fix. Recording AT THE READ gives every site a
// surface for free while keeping its own behaviour.
enum ResponseRead<Value> {
    case decoded(Value)
    case undecodable(reason: String)

    var value: Value? {
        guard case .decoded(let value) = self else { return nil }
        return value
    }
}

extension ResponseRead: Sendable where Value: Sendable {}
extension ResponseRead: Equatable where Value: Equatable {}

enum ResponseBody {

    // A JSON object body. Both halves are inside the read, and that matters: `jsonObject` succeeding on
    // an array while the `as? [String: Any]` fails is the same defect wearing a better disguise, and a
    // `try?` written around only the throwing half cannot see it at all.
    static func json(_ data: Data, from endpoint: String,
                     recorder: ResponseDecodeFailures = .shared) -> ResponseRead<[String: Any]> {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return record(endpoint: endpoint, reason: "the body is JSON but not an object",
                              recorder: recorder)
            }
            recorder.record(endpoint: endpoint, failed: false)
            return .decoded(object)
        } catch {
            return record(endpoint: endpoint, reason: ResponseDecodeFailure.describe(error),
                          recorder: recorder)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, endpoint: String,
                                     recorder: ResponseDecodeFailures = .shared) -> ResponseRead<T> {
        do {
            let value = try JSONDecoder().decode(type, from: data)
            recorder.record(endpoint: endpoint, failed: false)
            return .decoded(value)
        } catch {
            return record(endpoint: endpoint, reason: ResponseDecodeFailure.describe(error),
                          recorder: recorder)
        }
    }

    private static func record<T>(endpoint: String, reason: String,
                                  recorder: ResponseDecodeFailures) -> ResponseRead<T> {
        recorder.record(endpoint: endpoint, failed: true, reason: reason)
        return .undecodable(reason: reason)
    }
}

// Why a response could not be read, in words rather than a type name. Kept apart from
// `HandoffDecodeFailure` because the two describe different things to different surfaces, and folding
// them together would mean one sentence covering both, which describes neither (L11).
enum ResponseDecodeFailure {
    static func describe(_ error: any Error) -> String {
        switch error {
        case let decoding as DecodingError:
            switch decoding {
            case .keyNotFound(let key, _): return "a field the response should carry is missing: \(key.stringValue)"
            case .typeMismatch(_, let context), .valueNotFound(_, let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return path.isEmpty ? "a field is the wrong type" : "\(path) is the wrong type or empty"
            case .dataCorrupted(let context):
                return context.debugDescription.isEmpty ? "the body is not valid JSON"
                                                        : context.debugDescription
            @unknown default: return "the body could not be decoded"
            }
        default:
            return (error as NSError).localizedDescription
        }
    }
}

// How each endpoint is behaving, counted rather than reported one response at a time (L77).
//
// THE CONDITION IS A RUN OF FAILURES, not a proportion, and that choice is the whole design. A
// proportion needs a minimum volume floor or it fires on the first failure of the session, and a floor
// silences the SATURATION case, which is the one worth knowing: a proportion cannot tell one bad out of
// two from twelve bad out of twelve (L139). A run needs no floor, so an endpoint polled every minute
// and one read twice a day are judged by the same rule. A quiet endpoint does take longer to reach the
// threshold, which is honest rather than ideal: the alternative is an alarm on a single bad response,
// and an alert that cries wolf is ignored (L36).
//
// The run ENDS on a success and on nothing else, the same rule `HandoffReadFailures` follows: the
// condition is over when the thing works again, and no amount of elapsed time is evidence of that
// (L160). The TOTALS are kept across a recovery, because they are what says this endpoint has been
// unhealthy today, which a cleared record could not.
final class ResponseDecodeFailures: @unchecked Sendable {

    // Three in a row. Set above one so a single malformed response says nothing, and low enough that an
    // endpoint answering badly is named while Dan is still at the machine.
    static let failingRun = 3

    struct Health: Equatable, Sendable {
        var endpoint: String
        var attempts: Int
        var failures: Int
        var consecutiveFailures: Int
        var lastReason: String?
        var isFailing: Bool { consecutiveFailures >= ResponseDecodeFailures.failingRun }
    }

    // Injectable rather than only a singleton, so a test never reads or writes the register another
    // test is using (L2). Every call site takes it as a defaulted parameter.
    static let shared = ResponseDecodeFailures()

    private let lock = NSLock()
    private var health: [String: Health] = [:]

    func record(endpoint: String, failed: Bool, reason: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var h = health[endpoint] ?? Health(endpoint: endpoint, attempts: 0, failures: 0,
                                           consecutiveFailures: 0, lastReason: nil)
        h.attempts += 1
        if failed {
            h.failures += 1
            h.consecutiveFailures += 1
            if let reason { h.lastReason = reason }
        } else {
            h.consecutiveFailures = 0
        }
        health[endpoint] = h
    }

    // Sorted by endpoint so a surface reading this is stable between polls rather than reshuffling.
    // Endpoints that have never failed are left out: this is a register of trouble, and a list of
    // everything the app has ever called is not something anybody reads.
    func current() -> [Health] {
        lock.lock()
        defer { lock.unlock() }
        return health.values.filter { $0.failures > 0 }.sorted { $0.endpoint < $1.endpoint }
    }

    func failing() -> [Health] { current().filter(\.isFailing) }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        health = [:]
    }
}
