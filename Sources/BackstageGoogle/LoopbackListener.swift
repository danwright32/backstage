// Ported-From: danwright32/overture mac/Overture/Integration/LoopbackListener.swift @ 0bb3869c8f71777d08712e9fa146fd07c6da699f
// Ported-Adapted: c9094fc97bb843b529d29f3c5a28bdee8a56f4c412b19f02dce786940ac91959
//
// Ported on 2026-09-19 by backstage#2. Do not edit this copy to fix a fault that is also in
// the origin: fix it there and re-port (L263).
//
// TAKEN WHOLE, then given an injectable sleep and bind (backstage#13) so its retry schedule is
// testable without waiting; the defaults are the origin's own. There is no OAuth flow without it: it is
// the local server that catches Google's redirect back to the app.
//
// ADAPTED AGAIN by backstage#60, and deliberately NOT a fault fix at the origin. It is PUBLIC now, with
// the port a parameter, because this package has a second consumer whose redirect URI is registered at
// a fixed port and therefore has to be built before anything is bound. Overture, the origin, assigns
// its port and has no use for either change, so there is nothing here to fix there: this is the package
// being a package (L263 covers the fault case, not this one).
import Foundation
import Network

// Binds an IPv4 loopback TCP listener on an OS-assigned port for the OAuth redirect
// catch. Two things have to be right or the live Gmail connect hangs (#51):
//   1. IPv4: Google redirects the browser to http://127.0.0.1; without forcing IPv4
//      NWListener can bind IPv6 and the redirect never arrives.
//   2. The real port is only valid once the listener reaches .ready. Reading it before
//      then returns 0, which produced redirect_uri=http://127.0.0.1:0, an address the
//      browser can't connect to, so the consent page never redirects back.
public enum LoopbackListener {
    public enum LoopbackError: LocalizedError {
        case noPort, failed(String), timedOut
        // #3409: a bind refused at THIS instant, which is worth another attempt. A separate case rather
        // than a flag on `failed`, so the retry loop asks the error what it is instead of re-reading the
        // words somebody chose for it (L35).
        case bindRefusedForNow(String)
        public var errorDescription: String? {
            switch self {
            case .noPort: return "Local login listener never reported a port."
            case .failed(let m): return "Local login listener failed: \(m)"
            // Its own sentence, not `failed`'s. It says the thing that is true of this case and not of
            // that one: every attempt was spent, and the condition is one that clears, so pressing the
            // control again is an action that changes the state the person is stuck in (L111).
            case .bindRefusedForNow(let m):
                return "Local login listener couldn't get a port after \(LoopbackListener.bindAttempts) "
                    + "tries: \(m). Connecting again usually works."
            case .timedOut: return "Couldn't open the local login listener (timed out)."
            }
        }
    }

    /// How long the bind is given before Connect Gmail gives up (#54).
    ///
    /// Named rather than written inline so the shipped value has a reader. It is short on purpose: a
    /// PERSON is waiting on this, having just pressed Connect Gmail, and a wedged bind that is not
    /// refused leaves them looking at a control that did nothing (L110, L148). The tests deliberately do
    /// NOT run at this value, because under parallel testing a saturated machine can delay the readiness
    /// callback by tens of seconds and the test would then be measuring the machine rather than the
    /// listener (#3266, L290); they pass their own far larger ceiling and assert this one separately.
    public static let defaultTimeout: TimeInterval = 10

    /// How many times the bind is attempted before the failure is the answer (#3409).
    ///
    /// A full parallel test run on 2026-08-31 failed three binds with
    /// `POSIXErrorCode(rawValue: 49): Can't assign requested address`, and the next run of the same tree
    /// passed all three. EADDRNOTAVAIL is not a port already taken (that is 48) and 127.0.0.1 does not
    /// stop being a local address, so what it reports is a bind refused at that instant.
    ///
    /// Both of the causes that suggested themselves were measured and ruled out: 400 concurrent binds
    /// with these exact parameters, and 400 more with `allowLocalEndpointReuse` off, all 800 reached
    /// `.ready` on this Mac. So the parameters are not it and neither is the count of listeners. A
    /// transient refusal is answered by another attempt, not by a different address.
    ///
    /// Small on purpose. The attempts share the caller's deadline rather than each getting their own, so
    /// this is a number of tries inside one wait, not a multiplier on how long a person waits.
    public static let bindAttempts = 3

    /// How long to wait before trying again. Short, because the condition being waited out is momentary
    /// and the waiting comes out of the caller's own budget.
    public static let bindRetryDelay: TimeInterval = 0.1

    /// Whether a bind failure is one that could plausibly clear on its own.
    ///
    /// A permanent failure (no permission, no route) has to be reported at once: retrying it spends the
    /// person's whole timeout to arrive at the same answer more slowly (L110).
    ///
    /// It reads the POSIX code out of the TYPED error rather than looking for digits in the text
    /// `NWError` renders, which is the whole reason this is decided here, at the one place the type still
    /// exists, and carried onward as its own error case (L35). The first version matched on the message,
    /// and a message is a rendering: it can be reworded by the framework, localised, or made to say
    /// `rawValue: 490` where a substring reader sees 49.
    ///
    /// EADDRINUSE STAYS TRANSIENT ON A NAMED PORT, and this was tried the other way first
    /// (backstage#60). The argument for making it permanent there sounded right: on an assigned port a
    /// busy address means the OS picked badly and picking again is the answer, while on a port the
    /// consumer NAMED it looks like another process holds it and will still hold it in 100ms.
    ///
    /// MEASURED, and it is wrong. The first test written against the new behaviour bound an assigned
    /// port, cancelled it and asked for that same port back, and got EADDRINUSE: `cancel()` returns
    /// before the socket has finished winding down. So a named port has TWO causes for that code, a
    /// process that holds it and a socket that is still letting go, they are indistinguishable from the
    /// code alone, and the second is the common one. It is what happens when somebody presses Connect,
    /// closes the window and presses Connect again.
    ///
    /// Retrying costs three attempts inside the caller's own wait, which is a fraction of a second, and
    /// it rescues that case. Reporting at once would have turned the commonest retry into a refusal.
    /// The attempts being spent is still its own message, `bindRefusedForNow`, so a port genuinely held
    /// by something else is reported as such rather than as a generic failure.
    static func isTransientBindFailure(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        return code == .EADDRNOTAVAIL || code == .EADDRINUSE
    }

    /// What is left of the caller's wait, never negative: a negative budget handed to a sleep or a
    /// timeout reads as no limit at all, which is the one failure a deadline exists to prevent.
    static func remainingBudget(deadline: TimeInterval, now: TimeInterval) -> TimeInterval {
        max(0, deadline - now)
    }

    /// The parameters every bind here uses, as their own function so what is ASKED FOR can be read
    /// without binding anything (backstage#60). A test that binds and reads the result back cannot tell
    /// a request for a port from the OS happening to assign that port.
    ///
    /// Bind to the IPv4 loopback only (#53): the OAuth redirect always comes from this machine's browser
    /// to http://127.0.0.1, so there is no reason to accept connections on any other interface. Pinning
    /// 127.0.0.1 also forces IPv4, without which `NWListener` can bind IPv6 and the redirect never
    /// arrives (#51).
    ///
    /// `port` nil is the OS assigning one, which is what Gmail wants: it builds its redirect URI after
    /// the bind, from the port that came back. A consumer that registered a fixed redirect URI names its
    /// port instead, and then the port is part of the request rather than part of the answer.
    static func parameters(port: UInt16?) -> NWParameters {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let endpointPort: NWEndpoint.Port = port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: endpointPort)
        return params
    }

    public static func start(
        queue: DispatchQueue,
        timeout: TimeInterval = LoopbackListener.defaultTimeout,
        // backstage#60: the port a consumer needs, or nil to let the OS assign one. Nil is the default,
        // so every existing call site keeps the behaviour it was written against.
        port: UInt16? = nil,
        log: (@Sendable (String) -> Void)? = nil,
        // backstage#13: the retry pause and the bind itself are injectable, so the retry schedule can
        // be asserted from the delays it ASKED FOR rather than lived through (L524). The defaults are
        // the origin's real clock and real bind.
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        bind: ((TimeInterval) async throws -> (listener: NWListener, port: UInt16))? = nil,
        onConnection: @escaping @Sendable (NWConnection) -> Void
    ) async throws -> (listener: NWListener, port: UInt16) {
        let attemptBind = bind ?? { budget in
            try await startOnce(
                queue: queue, timeout: budget, port: port, log: log, sleep: sleep,
                onConnection: onConnection
            )
        }
        let deadline = Date().timeIntervalSince1970 + timeout
        var lastError: Error = LoopbackError.timedOut

        for attempt in 1...bindAttempts {
            let budget = remainingBudget(deadline: deadline, now: Date().timeIntervalSince1970)
            // Out of time is the caller's own answer, whatever the last attempt said: another attempt
            // here would be waiting past the moment the person was promised.
            guard budget > 0 else { break }
            do {
                return try await attemptBind(budget)
            } catch let error as LoopbackError {
                guard case .bindRefusedForNow(let message) = error, attempt < bindAttempts
                else { throw error }
                lastError = error
                // copy-inventory:ignore-start  developer diagnostic log, not the app's voice (#915)
                log?("bind refused (\(message)); attempt \(attempt) of \(bindAttempts), trying again")
                // copy-inventory:ignore-end
                try? await sleep(bindRetryDelay)
            }
        }
        throw lastError
    }

    private static func startOnce(
        queue: DispatchQueue,
        timeout: TimeInterval,
        port: UInt16?,
        log: (@Sendable (String) -> Void)?,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
        onConnection: @escaping @Sendable (NWConnection) -> Void
    ) async throws -> (listener: NWListener, port: UInt16) {
        let params = parameters(port: port)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = onConnection

        return try await withCheckedThrowingContinuation { cont in
            let box = ContinuationBox(cont)
            // Give up if the listener never reaches .ready, so Connect Gmail can't hang on a
            // wedged bind (#54). The box resumes once, so whichever fires first wins.
            //
            // CRITICAL: the sleep MUST propagate cancellation. When .ready fires it calls
            // timeoutTask.cancel(); a `try?` there would SWALLOW the CancellationError and fall through to
            // listener.cancel(), tearing down the just-ready listener so the browser's redirect hits a dead
            // port ("Safari can't connect to 127.0.0.1"). The `catch { return }` leaves a live, ready
            // listener alone; only a genuine 10s timeout reaches cancel().
            let timeoutTask = Task {
                do {
                    // backstage#13: the same injected sleep as the retry pause, so no wait in this file
                    // runs on a clock a test cannot control. It must still THROW on cancellation, which
                    // the default real sleep does, for the reason set out just above.
                    try await sleep(timeout)
                } catch {
                    return
                }
                box.resume(throwing: LoopbackError.timedOut)
                listener.cancel()
            }
            listener.stateUpdateHandler = { state in
                // Logged so a listener that reports .ready and then quietly drops its socket (the bug
                // where the browser hits a dead port) is visible as a state transition after .ready.
                // copy-inventory:ignore-start  developer diagnostic log, not the app's voice (#915)
                log?("listener state: \(state)")
                // copy-inventory:ignore-end
                switch state {
                case .ready:
                    timeoutTask.cancel()
                    if let port = listener.port?.rawValue, port != 0 {
                        box.resume(returning: (listener, port))
                    } else {
                        box.resume(throwing: LoopbackError.noPort)
                    }
                case .failed(let error):
                    timeoutTask.cancel()
                    // #3409: released here, because a failed attempt may be followed by another one and a
                    // listener left behind per attempt is a leak the retry would introduce.
                    listener.cancel()
                    box.resume(throwing: isTransientBindFailure(error)
                        ? LoopbackError.bindRefusedForNow("\(error)")
                        : LoopbackError.failed("\(error)"))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }
}

// One-shot resume guard: the listener's state handler can fire more than once, but a
// CheckedContinuation must resume exactly once (it traps otherwise).
private final class ContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    init(_ cont: CheckedContinuation<T, Error>) { self.cont = cont }

    func resume(returning value: sending T) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(returning: value)
    }
    func resume(throwing error: Error) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(throwing: error)
    }
}
