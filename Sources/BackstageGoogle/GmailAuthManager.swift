// Ported-From: danwright32/overture mac/Overture/Integration/GmailAuthManager.swift @ 0bb3869c8f71777d08712e9fa146fd07c6da699f
//
// Ported on 2026-09-19 by backstage#2 (step 4b). Do not edit this copy to fix a fault that is also in
// the origin: fix it there and re-port (L263).
//
// DELIBERATE CHANGES. The origin is one app's sign in; this is a package three apps share, so it holds
// no consumer's state, content or defaults:
//   1. No global instance. Each consumer constructs one, naming the directory its credentials live in.
//   2. NO DEFAULT SCOPE LIST (backstage#3). The origin requested its own three scopes, one of which
//      Ovation does not need. `scopes` has no default, so a consumer that names none does not compile
//      (scripts/test-scopes-required.sh builds one to prove it), and an EMPTY list is refused here.
//   3. No prefilled account. The origin passed its owner's address as the login hint; this takes an
//      optional hint from the consumer, and sends none when given none.
//   4. The log is a closure the consumer passes. The origin wrote into its own app's log folder.
//   5. No signature fetch after connecting. That was the origin's own signature machinery.
//   6. backstage#5: the live browser and the live network both refuse inside a test run.
//   7. backstage#13: every wait (the give up, the heartbeat, the probe and the listener's retry)
//      runs on the one injected sleep, and every "now" on the injected clock.
//   8. The messages name no app and no app's button.
// The flow itself, and the reasoning recorded against each part of it, are the origin's.
import Foundation
import AppKit
import Network

// Runs the OAuth desktop flow: opens Google's consent page in the browser, catches the redirect on a
// loopback listener, exchanges the code for tokens, and persists them. Also vends a fresh access token,
// refreshing when stale. Sends nothing; this only obtains permission.
@MainActor
public final class GmailAuthManager {

    public enum AuthError: LocalizedError, Equatable {
        case noClientConfig, notConnected, listenerFailed, listenerUnreachable, stateMismatch
        case exchangeFailed(String), refreshFailed(String), authExpired, tokenSaveFailed, alreadyConnecting
        case noScopes
        public var errorDescription: String? {
            switch self {
            case .noClientConfig: return "The Gmail client configuration is missing."
            case .notConnected: return "Gmail isn't connected yet."
            case .listenerFailed: return "Couldn't open the local sign-in listener."
            case .listenerUnreachable: return "Couldn't start the Gmail sign-in on this Mac, so the browser was not opened."
            case .stateMismatch: return "The sign-in response didn't match the request. Try again."
            case .exchangeFailed(let m): return "Sign-in failed: \(m)"
            case .refreshFailed(let m): return "Gmail couldn't refresh right now (temporary): \(m)"
            case .authExpired: return "Gmail access expired or was revoked, so it needs connecting again."
            case .tokenSaveFailed: return "Couldn't save the Gmail credentials to disk. Check available storage and try again."
            case .alreadyConnecting: return "A Gmail sign-in is already in progress. Finish it in the browser."
            case .noScopes: return "No Gmail permissions were named, so there is nothing to ask Google for."
            }
        }
    }

    // backstage#15: whether token refresh is having a blip or an outage.
    //
    // A temporary failure is deliberately answered "try again", because the other answer signs somebody
    // out over a passing fault. But an error classified as expected must still be counted against a
    // rate (L77), or one bad response and Google being unreachable for an hour arrive on the same path
    // and look identical, and the only symptom a person sees is that mail quietly stops going out.
    //
    // So each temporary failure is counted, the run is dated from its FIRST failure (so a consumer can
    // say "Gmail has not refreshed since 14:02", L589), and a success ends it. A dead login is not a
    // temporary failure: it clears the tokens and has its own remedy, so it ends the run too.
    public struct RefreshHealth: Equatable, Sendable {
        public var consecutiveTemporaryFailures: Int
        public var failingSince: Date?

        // THREE, and why: one or two temporary failures are ordinary contention that the next attempt
        // usually clears. Three in a row with no success between them is past what a person retrying
        // by hand would call a blip, and it is the point at which "try again" stops being true.
        public static let sustainedAfter = 3
        public var isSustained: Bool { consecutiveTemporaryFailures >= Self.sustainedAfter }
        public static let healthy = RefreshHealth(consecutiveTemporaryFailures: 0, failingSince: nil)
    }

    public private(set) var refreshHealth: RefreshHealth = .healthy

    public let scopes: [String]
    public let loginHint: String?
    private let clientURL: URL
    private let tokenURL: URL
    private let log: (@Sendable (String) -> Void)?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let openBrowser: (@MainActor (URL) -> Void)?

    public init(credentialsDirectory: URL,
                scopes: [String],
                loginHint: String? = nil,
                log: (@Sendable (String) -> Void)? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil,
                // Nil means the live network, which refuses inside a test run (backstage#5).
                fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
                // Nil means the person's real browser, which is refused inside a test run.
                openBrowser: (@MainActor (URL) -> Void)? = nil) throws {
        guard !scopes.isEmpty else { throw AuthError.noScopes }
        self.scopes = scopes
        self.loginHint = loginHint
        self.clientURL = GmailCredentials.clientConfigURL(in: credentialsDirectory)
        self.tokenURL = GmailCredentials.tokenURL(in: credentialsDirectory)
        self.log = log
        self.now = now
        self.sleep = sleep ?? { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        self.fetch = fetch ?? { try await GmailNetworking.live($0) }
        self.openBrowser = openBrowser
    }

    private var listener: NWListener?
    private var pendingState: String?
    private var pendingPKCE: PKCE?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    // Origin #1167: re-probes the listener partway through the wait. The pre-browser probe cannot catch a
    // listener that only dies AFTER the app backgrounds during consent, so this catches that residual case
    // and fails fast instead of waiting out the whole give-up window.
    private var heartbeatTask: Task<Void, Never>?
    // The re-entrancy latch. A second connect() cancelling the first's listener on the very port Google is
    // about to redirect to is what produced "can't connect to 127.0.0.1" in the origin (a single tap can
    // fire a SwiftUI toolbar action twice). Set and cleared only through begin/endConnectAttempt.
    private var isConnecting = false

    // Atomically claims the connect flow. Main actor, with no await between the check and the set, so two
    // calls racing can never both win.
    func beginConnectAttempt() -> Bool {
        if isConnecting { return false }
        isConnecting = true
        return true
    }

    func endConnectAttempt() { isConnecting = false }

    public var isConnected: Bool { GmailCredentials.isConnected(tokensAt: tokenURL) }

    // Begin the consent flow: open the browser, await the loopback redirect, exchange the code, and store
    // tokens. Throws on any failure; sends nothing.
    public func connect(hardTimeout: TimeInterval = 90, heartbeatInterval: TimeInterval = 15,
                        probe: ((UInt16) async -> Bool)? = nil) async throws {
        // backstage#5: decided BEFORE anything is bound or opened, so a test that forgot to inject a
        // browser fails by name and no tab ever appears on the machine running it.
        let open: @MainActor (URL) -> Void
        if let openBrowser { open = openBrowser }
        else if let refused = GmailNetworking.refusal(underTests: GmailNetworking.isTestRun()) { throw refused }
        else { open = { NSWorkspace.shared.open($0) } }
        let sleep = self.sleep
        let probe = probe ?? { await GmailAuthManager.probeListenerReachable(port: $0, sleep: sleep) }

        guard beginConnectAttempt() else { throw AuthError.alreadyConnecting }
        defer { endConnectAttempt() }
        log?("connect() begin")

        // Hold an activity assertion for the whole flow so App Nap does NOT suspend the app while it waits
        // in the background (the browser is frontmost during consent). A napped app stops servicing its
        // main queue, so the listener silently stops accepting and Google's redirect hits a dead port.
        let napBlocker = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Connecting Gmail")
        defer { ProcessInfo.processInfo.endActivity(napBlocker) }

        guard let client = GmailCredentials.loadClient(from: clientURL) else { throw AuthError.noClientConfig }

        // Cancel any half-finished PRIOR attempt. The latch guarantees this never runs against a live one.
        cancelInFlight()

        let port = try await startListener()
        log?("listener ready on 127.0.0.1:\(port)")

        // Origin #1163: confirm the just-bound listener actually accepts a connection BEFORE opening the
        // browser, so a dead listener fails in about two seconds with a retryable error and no dead tab.
        guard await probe(UInt16(port)) else {
            log?("listener probe failed on 127.0.0.1:\(port); aborting before opening the browser")
            stopListener()
            throw AuthError.listenerUnreachable
        }

        let redirect = "http://127.0.0.1:\(port)"
        let pkce = GoogleOAuth.makePKCE(verifierBytes: Self.randomBytes(32))
        let state = Self.randomURLSafe(16)
        pendingState = state
        pendingPKCE = pkce

        let config = OAuthConfig(clientId: client.clientId, clientSecret: client.clientSecret,
                                 redirectURI: redirect, scopes: scopes)
        let authURL = GoogleOAuth.authorizationURL(config: config, pkce: pkce, state: state, loginHint: loginHint)
        open(authURL)
        log?("opened browser to Google; awaiting redirect on port \(port)")

        // Auto give up, so a caller can never wait for ever if the redirect never arrives.
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await sleep(hardTimeout)
            await MainActor.run { self?.failTimeout() }
        }

        // Origin #1167: heartbeat. Re-probe while waiting; if the listener has gone unreachable and no
        // redirect has arrived, fail fast rather than waiting out the give up.
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await sleep(heartbeatInterval) } catch { return }
                guard let self, !Task.isCancelled, self.codeContinuation != nil else { return }
                if await probe(UInt16(port)) { continue }
                guard self.codeContinuation != nil else { return }
                self.failListenerDied()
                return
            }
        }

        let code = try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            codeContinuation = c
        }
        timeoutTask?.cancel()
        heartbeatTask?.cancel()
        stopListener()

        let tokens = try await exchange(config: config, code: code, pkce: pkce)
        try persistExchangedTokens(tokens)
    }

    // Split from connect() so a failed save after a real consent grant is testable (origin #484): the
    // person has already seen Google's consent screen and has no other signal something went wrong.
    func persistExchangedTokens(_ tokens: OAuthTokens) throws {
        guard let refresh = tokens.refreshToken else {
            throw AuthError.exchangeFailed("Google did not return a refresh token. Revoke prior access and retry.")
        }
        let stored = StoredTokens(refreshToken: refresh, accessToken: tokens.accessToken,
                                  accessTokenExpiry: tokens.expiresIn.map { now().addingTimeInterval(TimeInterval($0)) })
        guard GmailCredentials.saveTokens(stored, to: tokenURL) else { throw AuthError.tokenSaveFailed }
    }

    // A valid access token, refreshing through the stored refresh token when stale.
    public func validAccessToken() async throws -> String {
        guard let client = GmailCredentials.loadClient(from: clientURL) else { throw AuthError.noClientConfig }
        guard var stored = GmailCredentials.loadTokens(from: tokenURL) else { throw AuthError.notConnected }
        let now = self.now()
        if stored.isFresh(now: now), let token = stored.accessToken { return token }

        let config = OAuthConfig(clientId: client.clientId, clientSecret: client.clientSecret,
                                 redirectURI: "http://127.0.0.1", scopes: scopes)
        let req = GoogleOAuth.refreshRequest(config: config, refreshToken: stored.refreshToken)
        let (data, resp) = try await fetch(req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        switch GoogleOAuth.interpretRefreshResponse(status: status, data: data) {
        case .success(let tokens):
            stored.accessToken = tokens.accessToken
            stored.accessTokenExpiry = tokens.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
            guard GmailCredentials.saveTokens(stored, to: tokenURL) else { throw AuthError.tokenSaveFailed }
            refreshHealth = .healthy
            return tokens.accessToken
        case .failure(.authExpired):
            refreshHealth = .healthy
            // The refresh token is dead. Clear it so the consumer shows disconnected, instead of failing
            // opaquely.
            GmailCredentials.clearTokens(at: tokenURL)
            throw AuthError.authExpired
        case .failure(.transient):
            refreshHealth.consecutiveTemporaryFailures += 1
            if refreshHealth.failingSince == nil { refreshHealth.failingSince = now }
            throw AuthError.refreshFailed(String(data: data, encoding: .utf8) ?? "unknown")
        }
    }

    public func disconnect() { GmailCredentials.clearTokens(at: tokenURL) }

    // Called when a live API call rejects the token mid-session: drop it so the consumer shows
    // disconnected (origin #50). GmailSender's onAuthExpired is where a consumer wires this.
    public func signalAuthExpired() { GmailCredentials.clearTokens(at: tokenURL) }

    // MARK: - token exchange

    private func exchange(config: OAuthConfig, code: String, pkce: PKCE) async throws -> OAuthTokens {
        let req = GoogleOAuth.tokenExchangeRequest(config: config, code: code, pkce: pkce)
        let (data, resp) = try await fetch(req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let tokens = ResponseBody.decode(OAuthTokens.self, from: data, endpoint: "google.oauth.exchange").value
        else { throw AuthError.exchangeFailed(String(data: data, encoding: .utf8) ?? "unknown") }
        return tokens
    }

    // MARK: - loopback listener

    // The listener runs on its OWN queue, not the main queue: when the browser comes forward the app goes
    // to the background, and a listener bound to a throttled main queue can report ready while holding no
    // socket.
    nonisolated private static let listenerQueue = DispatchQueue(label: "backstage.gmail-loopback")

    // Origin #1163: a fast health check on the just-bound listener, before opening the browser. Bounded by
    // the injected sleep, so a wedged attempt cannot hang the connect flow and a test need not wait on it.
    nonisolated static func probeListenerReachable(port: UInt16, timeout: TimeInterval = 2,
                                                   sleep: @escaping @Sendable (TimeInterval) async throws -> Void) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let conn = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        let once = ProbeLatch()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire() { cont.resume(returning: true) }
                    conn.cancel()
                case .failed, .cancelled:
                    if once.fire() { cont.resume(returning: false) }
                default:
                    break
                }
            }
            conn.start(queue: Self.listenerQueue)
            Task {
                try? await sleep(timeout)
                if once.fire() { cont.resume(returning: false); conn.cancel() }
            }
        }
    }

    private func startListener() async throws -> Int {
        let log = self.log
        let (listener, port) = try await LoopbackListener.start(
            queue: Self.listenerQueue, log: log, sleep: sleep
        ) { [weak self] conn in
            conn.start(queue: Self.listenerQueue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                Task { @MainActor in self?.handleRedirect(request: request, conn: conn) }
            }
        }
        self.listener = listener
        return Int(port)
    }

    private func handleRedirect(request: String, conn: NWConnection) {
        let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
        let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let comps = URLComponents(string: "http://127.0.0.1\(path)")
        let code = comps?.queryItems?.first { $0.name == "code" }?.value
        let state = comps?.queryItems?.first { $0.name == "state" }?.value

        // Origin #1163: only a genuine OAuth redirect resolves the waiting sign-in. A connection carrying
        // neither a code nor a state is the health probe, a port scan or a prefetch, and resolving the
        // waiter from one would fail a healthy connect with a bogus mismatch.
        guard code != nil || state != nil else {
            log?("ignored a non-redirect connection (no code or state)")
            conn.cancel(); return
        }
        log?("redirect received by the listener")

        // backstage#25: the page says only what is true WHEN IT IS SHOWN. It is answered the moment the
        // code arrives, before the exchange and the save, either of which can still fail, so it must not
        // say the account is connected (L12, L11). The app reports the real outcome where the person is.
        let body = "<html><body style='font-family:-apple-system;padding:40px'>Google's response reached the app. You can close this tab and return to it.</body></html>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })

        let cont = codeContinuation
        codeContinuation = nil
        guard state == pendingState else { cont?.resume(throwing: AuthError.stateMismatch); return }
        guard let code else { cont?.resume(throwing: AuthError.exchangeFailed("no code in redirect")); return }
        cont?.resume(returning: code)
    }

    private func stopListener() { listener?.cancel(); listener = nil }

    private func cancelInFlight() {
        if codeContinuation != nil { log?("tearing down an attempt that was still waiting for the redirect") }
        timeoutTask?.cancel(); timeoutTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        stopListener()
        let cont = codeContinuation
        codeContinuation = nil
        pendingState = nil
        pendingPKCE = nil
        cont?.resume(throwing: CancellationError())
    }

    private func failTimeout() {
        guard codeContinuation != nil else { return }
        log?("timed out waiting for the redirect")
        timeoutTask?.cancel(); timeoutTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        stopListener()
        let cont = codeContinuation
        codeContinuation = nil
        pendingState = nil
        pendingPKCE = nil
        cont?.resume(throwing: AuthError.exchangeFailed("Timed out waiting for Google. Close any old browser tabs and try again."))
    }

    private func failListenerDied() {
        guard codeContinuation != nil else { return }
        log?("listener went unreachable mid-wait; failing fast before the give-up window")
        timeoutTask?.cancel(); timeoutTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        stopListener()
        let cont = codeContinuation
        codeContinuation = nil
        pendingState = nil
        pendingPKCE = nil
        cont?.resume(throwing: AuthError.listenerUnreachable)
    }

    // MARK: - randomness

    private static func randomBytes(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes)
    }
    private static func randomURLSafe(_ n: Int) -> String { GoogleOAuth.base64url(randomBytes(n)) }
}

// One-shot resume guard for the reachability probe: the connection's state handler and the timeout
// task race to resolve the continuation, but a CheckedContinuation must resume exactly once.
private final class ProbeLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
