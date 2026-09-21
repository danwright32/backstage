import Foundation
import Network

/// Catches Google's redirect on a loopback port and hands back the code, or a typed reason it did
/// not (backstage#61).
///
/// NOT PORTED, and deliberately so. Its four behaviours (waiting for the redirect, reading the
/// request line, answering the browser, matching the state) were lifted out of `GmailAuthManager`,
/// which is the origin's file, because a second consumer of the same catch could reach none of them
/// and therefore carried its own copy of all four. Lifting them here is the change that ends that
/// duplication rather than adding a shared thing beside it: the Gmail manager consumes this, so
/// there is one implementation (L613, L370).
///
/// WHAT DIFFERS PER CONSUMER IS AN INPUT: the product name the tab is sent back to, the state to
/// match, and the port. Everything else is one rule in one place.
///
/// THE STATE IS REQUIRED, with no way to ask for the match to be skipped. It is the only thing
/// standing between this port and a code somebody else put there, so a consumer that does not yet
/// send one starts sending one rather than the package offering an off switch: a control that
/// exists to protect somebody fails closed (L42, L72).
@MainActor
public final class GoogleRedirectCatcher {

    /// What came back on the loopback port. All three are optional because all three can be absent:
    /// a request that is not a redirect at all parses to an empty answer rather than to nothing.
    public struct Answer: Equatable, Sendable {
        public let code: String?
        public let error: String?
        public let state: String?
        public init(code: String?, error: String?, state: String?) {
            self.code = code
            self.error = error
            self.state = state
        }
    }

    /// Which of the three things happened, which is what the tab is told.
    ///
    /// It is deliberately NOT the same vocabulary as `Failure`: the page is written the moment the
    /// redirect lands, before the state is matched, so it can only speak about what Google sent.
    public enum Outcome: Equatable, Sendable {
        case received
        case refused(String)
        case noAnswer
    }

    /// Why no code came back. Each one is a different thing to tell somebody (L11).
    public enum Failure: Error, Equatable, LocalizedError {
        case refusedByGoogle(String)
        case noCode
        case stateMismatch
        case timedOut
        case alreadyWaiting
        case alreadyStarted

        public var errorDescription: String? {
            switch self {
            case .refusedByGoogle(let reason): return "Google did not grant access: \(reason)"
            case .noCode: return "Google's response carried no sign-in code."
            case .stateMismatch: return "The sign-in response didn't match the request. Try again."
            case .timedOut: return "Timed out waiting for Google's response."
            case .alreadyWaiting: return "A sign-in is already waiting on this listener."
            case .alreadyStarted: return "This sign-in listener has already taken its port."
            }
        }
    }

    /// Taking the port, injected so the port a consumer ASKED FOR can be read without binding
    /// anything: a test that binds and reads the result back cannot tell a request for a port from
    /// the OS happening to assign that port (L70).
    public typealias Bind = @MainActor (
        _ port: UInt16?,
        _ timeout: TimeInterval,
        _ onConnection: @escaping @Sendable (NWConnection) -> Void
    ) async throws -> (listener: NWListener, port: UInt16)

    private let productName: String
    private let expectedState: String
    private let wantedPort: UInt16?
    private let queue: DispatchQueue
    private let log: (@Sendable (String) -> Void)?
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let bind: Bind?

    private var listener: NWListener?
    private var waiter: CheckedContinuation<String, Error>?
    private var deadlineTask: Task<Void, Never>?
    /// What this catch settled on, kept because it can be settled BEFORE anything is waiting for it.
    /// A redirect can land between the bind returning and the wait starting, and a catcher that
    /// forgot that would leave the wait hanging for ever, which cannot be told from slowness and
    /// holds the port while it does (L110).
    private var settled: Result<String, Error>?

    /// Whether this catch has its answer. True the moment the redirect is read, before anybody asks.
    public var hasSettled: Bool { settled != nil }

    /// Whether somebody is waiting on this catch right now. A consumer watching the listener from
    /// outside asks this before reporting it dead, so it does not speak about a wait that has
    /// already ended.
    public var isWaiting: Bool { waiter != nil }

    /// The port this catch is bound to, once it is.
    public private(set) var boundPort: UInt16?

    public init(productName: String,
                expectedState: String,
                port: UInt16? = nil,
                queue: DispatchQueue,
                log: (@Sendable (String) -> Void)? = nil,
                // backstage#13: every wait runs on an injected clock, so nothing here is waited out
                // for real in a test (L524). The default is the real one.
                sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil,
                bind: Bind? = nil) {
        self.productName = productName
        self.expectedState = expectedState
        self.wantedPort = port
        self.queue = queue
        self.log = log
        self.sleep = sleep ?? { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        self.bind = bind
    }

    // MARK: - taking the port

    /// Binds the loopback port and begins accepting, answering with the port that was taken.
    ///
    /// Separate from the wait because a consumer that lets the OS assign its port has to build its
    /// redirect URI from what came back, and therefore needs the port well before anybody is waiting
    /// for a redirect to it.
    @discardableResult
    public func start(timeout: TimeInterval = LoopbackListener.defaultTimeout) async throws -> UInt16 {
        // ONE CATCH, ONE PORT. Without this a second start replaced the listener without cancelling
        // it, and the abandoned one held its port for the life of the process, which is the exact
        // condition that makes the next attempt bind somewhere Google is not redirecting to.
        // Refused rather than made idempotent: a caller that started twice meant one of them, and
        // handing back the first port would be answering a question it did not ask.
        guard listener == nil, boundPort == nil else { throw Failure.alreadyStarted }
        let queue = self.queue
        let onConnection: @Sendable (NWConnection) -> Void = { [weak self] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                Task { @MainActor in self?.handle(request: request, on: connection) }
            }
        }
        let take = bind ?? liveBind
        let (listener, port) = try await take(wantedPort, timeout, onConnection)
        self.listener = listener
        self.boundPort = port
        return port
    }

    /// The shipping bind, which is the package's own listener: the IPv4 pinned endpoint and the
    /// typed retry for a bind refused at that instant both live there, so nothing here re-implements
    /// them.
    private var liveBind: Bind {
        let queue = self.queue
        let log = self.log
        let sleep = self.sleep
        return { port, timeout, onConnection in
            try await LoopbackListener.start(
                queue: queue, timeout: timeout, port: port, log: log, sleep: sleep,
                onConnection: onConnection
            )
        }
    }

    // MARK: - waiting for the redirect

    /// Waits for Google's redirect, answering with the code or throwing why there is none.
    ///
    /// The deadline runs on the injected sleep, and it is a deadline rather than an open wait
    /// because a wait with no limit cannot fail, only hang, and this one holds a port (L110).
    public func awaitCode(timeout: TimeInterval) async throws -> String {
        if let settled { return try settled.get() }
        guard waiter == nil else { throw Failure.alreadyWaiting }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            // Checked again inside the closure: the redirect can land between the two lines above
            // and this one running, and `settle` would then have nothing to resume.
            if let settled {
                continuation.resume(with: settled)
                return
            }
            waiter = continuation
            deadlineTask?.cancel()
            deadlineTask = Task { @MainActor [weak self] in
                // Cancellation is how a settled catch ends this task early, so it must not be
                // swallowed: a `try?` here would fire the give up on a catch that already answered.
                do { try await self?.sleep(timeout) } catch { return }
                self?.settle(.failure(Failure.timedOut))
            }
        }
    }

    /// Ends the wait with a reason of the consumer's own, for a fault only the consumer can see. The
    /// Gmail flow re-probes its listener while waiting and uses this to fail fast rather than
    /// waiting out the give up window it was meant to cut short.
    public func abandon(reason: Error) {
        settle(.failure(reason))
    }

    /// Lets the port go. Called on every settle, because a listener left running holds the port for
    /// the life of the process and the next attempt is redirected somewhere nothing is listening.
    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - reading what arrived

    private func handle(request: String, on connection: NWConnection) {
        guard let path = Self.requestedPath(from: request) else {
            // Not an HTTP request at all. This is what the Gmail flow's own reachability probe looks
            // like: it connects, sends nothing and goes away.
            connection.cancel()
            return
        }
        let answer = Self.answer(fromRedirectPath: path)

        // Only a genuine OAuth redirect resolves the waiting sign-in (origin #1163). A request
        // carrying none of a code, an error or a state is a favicon, a port scan or a prefetch, and
        // resolving the waiter from one would fail a healthy sign-in with a bogus mismatch.
        guard answer.code != nil || answer.error != nil || answer.state != nil else {
            log?("ignored a request that was not the redirect")
            connection.cancel()
            return
        }
        log?("redirect received by the listener")

        // Answered BEFORE the listener is torn down, so the browser shows a finished page rather
        // than a connection reset, which reads as the sign-in having failed.
        connection.send(
            content: Self.reply(productName: productName, for: Self.outcome(for: answer)),
            completion: .contentProcessed { _ in connection.cancel() }
        )

        settle(Self.result(for: answer, expectedState: expectedState))
    }

    /// What the wait is answered with, given what arrived.
    ///
    /// The state is matched FIRST, whatever else the redirect carries: a refusal that did not come
    /// from the request this listener made is not this sign-in's refusal.
    static func result(for answer: Answer, expectedState: String) -> Result<String, Error> {
        guard answer.state == expectedState else { return .failure(Failure.stateMismatch) }
        if let error = answer.error, answer.code == nil { return .failure(Failure.refusedByGoogle(error)) }
        guard let code = answer.code else { return .failure(Failure.noCode) }
        return .success(code)
    }

    /// The one place this catch settles, whichever route got here: the redirect, the deadline, or a
    /// consumer ending it. Everything after the first is ignored.
    private func settle(_ result: Result<String, Error>) {
        guard settled == nil else { return }
        settled = result
        deadlineTask?.cancel()
        deadlineTask = nil
        stop()
        let waiting = waiter
        waiter = nil
        waiting?.resume(with: result)
    }

    // MARK: - the parse, which needs no port

    /// The path out of an HTTP request line, or nil when this is not one.
    ///
    /// Nil rather than an empty path, because an empty path parses to a redirect carrying no code,
    /// and that is a different thing to tell somebody than a request that was not a redirect at all
    /// (L11). Google redirects the browser with GET, so nothing else is one.
    public nonisolated static func requestedPath(from request: String) -> String? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    /// Reads Google's redirect. One spelling of the rule, used by the live catch and by tests.
    public nonisolated static func answer(fromRedirectPath path: String) -> Answer {
        let items = URLComponents(string: "http://127.0.0.1\(path)")?.queryItems ?? []
        return Answer(code: items.first { $0.name == "code" }?.value,
                      error: items.first { $0.name == "error" }?.value,
                      state: items.first { $0.name == "state" }?.value)
    }

    /// Which of the three pages this answer earns.
    public nonisolated static func outcome(for answer: Answer) -> Outcome {
        if answer.code != nil { return .received }
        if let error = answer.error { return .refused(error) }
        return .noAnswer
    }

    // MARK: - what the browser tab is left showing

    /// The page, whole, so its length can be measured from it rather than restated.
    ///
    /// backstage#25 settled what the first of these may claim, and it is the base the other two were
    /// added to. The page is written the moment the redirect lands, BEFORE the token exchange and
    /// before the save, either of which can still fail, so it says Google's answer arrived and never
    /// that the account is connected (L12, L11). The app reports the real outcome where the person
    /// is. What Downbeat's copy had and this did not is the branch: somebody who was refused reads
    /// why in the tab they are already looking at.
    public nonisolated static func pageBody(productName: String, for outcome: Outcome) -> String {
        let name = escaped(productName)
        let body: String
        switch outcome {
        case .received:
            body = "<h1>Google's answer reached \(name).</h1>"
                + "<p>You can close this tab and return to \(name), where the result is shown.</p>"
        case .refused(let reason):
            // ANYTHING CAN REACH THIS PORT. A page opened at 127.0.0.1 with `?error=` is written by
            // whoever opened it, so what is quoted is escaped rather than rendered.
            body = "<h1>Access was not given.</h1>"
                + "<p>Google said: \(escaped(reason)). You can close this tab and return to "
                + "\(name) to try again.</p>"
        case .noAnswer:
            body = "<h1>Nothing to sign in with.</h1>"
                + "<p>This page was opened without an answer from Google. You can close this tab "
                + "and return to \(name) to try again.</p>"
        }
        return "<!doctype html><meta charset=\"utf-8\"><title>\(name)</title>"
            + "<body style=\"font-family:-apple-system,sans-serif;padding:3rem\">\(body)</body>"
    }

    /// The whole HTTP reply. The length is measured off the page it carries: a Content-Length that
    /// disagrees with the body leaves a tab loading for ever, which reads as the sign-in failing.
    public nonisolated static func reply(productName: String, for outcome: Outcome) -> Data {
        let page = pageBody(productName: productName, for: outcome)
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n"
        return Data((headers + page).utf8)
    }

    nonisolated static func escaped(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }
}
