// Ported-From: danwright32/overture mac/Overture/Integration/GmailAuthManager.swift @ 0bb3869c8f71777d08712e9fa146fd07c6da699f
// Ported-Adapted: b5b961793796847f8df1130dac88cf51ff0c0f9b2a9d7e882c3b361adbf09c7e
// Ported-Divergence: danwright32/overture#4035
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
//   9. backstage#61: the redirect catch is NOT here. Waiting for Google's redirect, reading the
//      request line, answering the browser and matching the state were four behaviours of this type
//      that a second consumer of the same catch could not reach, so it carried its own copy of all
//      four. They live in `GoogleRedirectCatcher` now and this consumes it, which is what makes it
//      one implementation rather than a shared one beside the old one (L613, L370). The consumer
//      names its product, because the page the browser is left showing has to say where to go back
//      to and the package names no app.
//  10. backstage#64: no `listenerFailed`. The origin publishes it and throws it from nothing; here a
//      bind that fails reaches the consumer as the listener's OWN typed error, which says which of
//      the bind failures it was, so a second generic sentence beside it could only be less true.
//  11. backstage#63: the reachability check is not here either. It is the catch's, because the port
//      is the catch's; this asks the catch about it, before the browser and again on the heartbeat.
//      The injectable probe seam stays, so no suite binds anything to drive either side of it.
//  12. backstage#68: the grant stored is the one Google REPORTED in its reply's `scope`, on the code
//      exchange and on every refresh, never the request. A reply naming no scope is refused by name,
//      and a narrower grant is refused naming what is missing. The origin records no grant, so this
//      extends #45's adaptation rather than repairing the origin.
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
        case noClientConfig, notConnected, listenerUnreachable, stateMismatch
        case exchangeFailed(String), refreshFailed(String), authExpired, tokenSaveFailed, alreadyConnecting
        case noScopes
        // backstage#61: Google itself said no. Its own word for why is the only thing that tells a
        // person whether to try again or to change something, and it used to be discarded into
        // "no code in redirect", which is what a malformed redirect says too (L11).
        case consentRefused(String)
        // backstage#68: Google's reply named no scope, so what it granted is unknown. Read as empty
        // it would be a refusal of everything, read as the request it would be the fault this
        // replaced, and it is neither (L215).
        case grantUnreported
        // backstage#68: Google granted less than was asked, typically a box unticked on the consent
        // screen. Names what is missing, because that is what the person has to grant next time.
        case scopesNotGranted([String])
        public var errorDescription: String? {
            switch self {
            case .noClientConfig: return "The Gmail client configuration is missing."
            case .notConnected: return "Gmail isn't connected yet."
            case .listenerUnreachable: return "Couldn't start the Gmail sign-in on this Mac, so the browser was not opened."
            case .stateMismatch: return "The sign-in response didn't match the request. Try again."
            case .exchangeFailed(let m): return "Sign-in failed: \(m)"
            case .refreshFailed(let m): return "Gmail couldn't refresh right now (temporary): \(m)"
            case .authExpired: return "Gmail access expired or was revoked, so it needs connecting again."
            case .tokenSaveFailed: return "Couldn't save the Gmail credentials to disk. Check available storage and try again."
            case .alreadyConnecting: return "A Gmail sign-in is already in progress. Finish it in the browser."
            case .noScopes: return "No Gmail permissions were named, so there is nothing to ask Google for."
            case .consentRefused(let why): return "Google did not grant access: \(why)"
            case .grantUnreported:
                return "Google's reply did not say which Gmail permissions it granted, so the sign-in was not saved. Try again."
            case .scopesNotGranted(let missing):
                return "Google granted less than was asked for. Not granted: \(missing.joined(separator: ", "))."
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
    /// What the browser tab is sent back to. Required rather than defaulted, for the reason the
    /// scope list is: a default here would be chosen once and inherited silently by three apps, and
    /// the only default available ("the app") is every app.
    public let productName: String
    private let clientURL: URL
    private let tokenURL: URL
    // WHAT COUNTS AS A THROWAWAY CREDENTIALS PATH inside a test run (backstage#44),
    // defaulting to the system temporary directory. Internal and settable so a suite
    // can drive the REFUSING branch without pointing at a credentials directory
    // somebody owns (L159). A consumer cannot reach it, so a consumer cannot widen it.
    var throwawayRoot: URL = FileManager.default.temporaryDirectory
    private let log: (@Sendable (String) -> Void)?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let openBrowser: (@MainActor (URL) -> Void)?

    public init(credentialsDirectory: URL,
                scopes: [String],
                productName: String,
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
        self.productName = productName
        self.loginHint = loginHint
        self.clientURL = GmailCredentials.clientConfigURL(in: credentialsDirectory)
        self.tokenURL = GmailCredentials.tokenURL(in: credentialsDirectory)
        self.log = log
        self.now = now
        self.sleep = sleep ?? { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        self.fetch = fetch ?? { try await GmailNetworking.live($0) }
        self.openBrowser = openBrowser
    }

    // backstage#61: the whole redirect catch, which used to be four methods and four fields here.
    // One per attempt, because a catch answers once and then lets its port go.
    private var catcher: GoogleRedirectCatcher?
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

    // WHAT THIS MANAGER IS CONNECTED FOR, judged against its OWN scopes
    // (backstage#45). A token granted for less than this consumer asks for is not
    // this consumer's authorization, however present its file is.
    public var connection: GmailGrantState {
        GmailCredentials.connection(at: tokenURL, wanting: scopes)
    }

    public var isConnected: Bool { connection.isConnected }

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

        // The state is minted BEFORE the bind, because the catch matches against it and a catch
        // that took its state later would have a window where it matched nothing.
        let pkce = GoogleOAuth.makePKCE(verifierBytes: Self.randomBytes(32))
        let state = Self.randomURLSafe(16)
        let catcher = GoogleRedirectCatcher(productName: productName, expectedState: state,
                                            queue: Self.listenerQueue, log: log, sleep: sleep)
        self.catcher = catcher
        let port = try await catcher.start()
        log?("listener ready on 127.0.0.1:\(port)")

        // Resolved here rather than at the top, because what answers this is the catch, which does
        // not exist until its port is taken. An injected one still wins, so no suite binds anything
        // to exercise the paths either side of it (L2).
        let probe: (UInt16) async -> Bool = probe ?? { _ in await catcher.reachable() }

        // Origin #1163: confirm the just-bound listener actually accepts a connection BEFORE opening the
        // browser, so a dead listener fails in about two seconds with a retryable error and no dead tab.
        guard await probe(port) else {
            log?("listener probe failed on 127.0.0.1:\(port); aborting before opening the browser")
            catcher.stop()
            self.catcher = nil
            throw AuthError.listenerUnreachable
        }

        let redirect = "http://127.0.0.1:\(port)"

        let config = OAuthConfig(clientId: client.clientId, clientSecret: client.clientSecret,
                                 redirectURI: redirect, scopes: scopes)
        let authURL = GoogleOAuth.authorizationURL(config: config, pkce: pkce, state: state, loginHint: loginHint)
        open(authURL)
        log?("opened browser to Google; awaiting redirect on port \(port)")

        // Origin #1167: heartbeat. Re-probe while waiting; if the listener has gone unreachable and no
        // redirect has arrived, fail fast rather than waiting out the give up. It is the one fault
        // only this consumer can see, which is why the catch takes a reason from outside at all.
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await sleep(heartbeatInterval) } catch { return }
                guard let self, !Task.isCancelled, catcher.isWaiting else { return }
                if await probe(port) { continue }
                guard catcher.isWaiting else { return }
                self.log?("listener went unreachable mid-wait; failing fast before the give-up window")
                catcher.abandon(reason: AuthError.listenerUnreachable)
                return
            }
        }

        // The give up lives in the catch, on the same injected clock, so there is one deadline
        // rather than one here and another inside what it is waiting on.
        let code: String
        do {
            code = try await catcher.awaitCode(timeout: hardTimeout)
        } catch {
            heartbeatTask?.cancel()
            self.catcher = nil
            throw (error as? GoogleRedirectCatcher.Failure).map(Self.authError(for:)) ?? error
        }
        heartbeatTask?.cancel()
        self.catcher = nil

        let tokens = try await exchange(config: config, code: code, pkce: pkce)
        try persistExchangedTokens(tokens)
    }

    // Split from connect() so a failed save after a real consent grant is testable (origin #484): the
    // person has already seen Google's consent screen and has no other signal something went wrong.
    func persistExchangedTokens(_ tokens: OAuthTokens) throws {
        guard let refresh = tokens.refreshToken else {
            throw AuthError.exchangeFailed("Google did not return a refresh token. Revoke prior access and retry.")
        }
        // THE GRANT IS RECORDED WITH THE TOKEN, never inferred later (backstage#45), and it is
        // the grant GOOGLE REPORTED, not the request (backstage#68). The account is whatever
        // Google returned, which is nil unless an identity scope was requested, and that absence
        // is recorded as honestly as a value would be.
        guard let granted = tokens.grantedScopes else { throw AuthError.grantUnreported }
        let missing = scopes.filter { !granted.contains($0) }
        // A NARROWER CONSENT NEVER REPLACES A LOGIN THAT ALREADY COVERS EVERYTHING (L5). Unticking a
        // box on a second consent does not revoke the first grant at Google, so the stored one is
        // still good. With nothing covering stored, the narrower grant IS saved, so the consumer
        // reads a mismatch naming what is missing rather than "never connected" (L11).
        if !missing.isEmpty && connection.isConnected { throw AuthError.scopesNotGranted(missing) }
        let obtained = now()
        let stored = StoredTokens(refreshToken: refresh, accessToken: tokens.accessToken,
                                  accessTokenExpiry: tokens.expiresIn.map { obtained.addingTimeInterval(TimeInterval($0)) },
                                  grantedScopes: granted, account: tokens.account,
                                  obtainedAt: obtained, lastConfirmedAt: obtained)
        guard try GmailCredentials.saveTokens(stored, to: tokenURL, throwaway: throwawayRoot) else { throw AuthError.tokenSaveFailed }
        guard missing.isEmpty else { throw AuthError.scopesNotGranted(missing) }
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
            // A REPLY NAMING NO SCOPE CONFIRMS NOTHING (backstage#68), so nothing is saved and the
            // confirmation stamp stays where it was. Not counted as a temporary failure either: it
            // is not a blip that the next attempt clears, it is Google answering in a shape this
            // cannot read, and it says so by name.
            guard let granted = tokens.grantedScopes else { throw AuthError.grantUnreported }
            stored.grantedScopes = granted
            stored.accessToken = tokens.accessToken
            stored.accessTokenExpiry = tokens.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
            // A SUCCESSFUL EXCHANGE IS THE ONLY EVIDENCE THE GRANT IS STILL LIVE,
            // so it is the only thing that moves this stamp (L454).
            stored.lastConfirmedAt = now
            guard try GmailCredentials.saveTokens(stored, to: tokenURL, throwaway: throwawayRoot) else { throw AuthError.tokenSaveFailed }
            refreshHealth = .healthy
            // What Google reports NOW is the grant, so it is recorded first and a narrowed one then
            // refused by name rather than handing out a token for less than this consumer needs.
            let missing = scopes.filter { !granted.contains($0) }
            guard missing.isEmpty else { throw AuthError.scopesNotGranted(missing) }
            return tokens.accessToken
        case .failure(.authExpired):
            refreshHealth = .healthy
            // The refresh token is dead. Clear it so the consumer shows disconnected, instead of failing
            // opaquely.
            try GmailCredentials.clearTokens(at: tokenURL, throwaway: throwawayRoot)
            throw AuthError.authExpired
        case .failure(.transient):
            refreshHealth.consecutiveTemporaryFailures += 1
            if refreshHealth.failingSince == nil { refreshHealth.failingSince = now }
            throw AuthError.refreshFailed(String(data: data, encoding: .utf8) ?? "unknown")
        }
    }

    public func disconnect() throws { try GmailCredentials.clearTokens(at: tokenURL, throwaway: throwawayRoot) }

    // Called when a live API call rejects the token mid-session: drop it so the consumer shows
    // disconnected (origin #50). GmailSender's onAuthExpired is where a consumer wires this.
    public func signalAuthExpired() throws { try GmailCredentials.clearTokens(at: tokenURL, throwaway: throwawayRoot) }

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

    /// Every way the catch can end, answered in this manager's own vocabulary.
    ///
    /// A `switch` over the whole enum rather than a lookup with a default, so a new way for the
    /// catch to end does not compile until somebody decides what it means here (L113).
    nonisolated static func authError(for failure: GoogleRedirectCatcher.Failure) -> AuthError {
        switch failure {
        case .stateMismatch: return .stateMismatch
        case .refusedByGoogle(let why): return .consentRefused(why)
        case .noCode: return .exchangeFailed("no code in redirect")
        case .timedOut:
            return .exchangeFailed("Timed out waiting for Google. Close any old browser tabs and try again.")
        // Two ways of saying one thing to a person: a catch that has already taken its port and one
        // that is already being waited on are both a sign-in under way. They stay separate where
        // they are produced, because there they are different faults, and meet here because the
        // person's answer to both is the same one (L260).
        case .alreadyWaiting, .alreadyStarted: return .alreadyConnecting
        }
    }

    private func cancelInFlight() {
        if catcher?.isWaiting == true { log?("tearing down an attempt that was still waiting for the redirect") }
        heartbeatTask?.cancel(); heartbeatTask = nil
        // Abandoning releases the port with it, so no route ends an attempt while leaving its
        // listener holding 127.0.0.1 for the life of the process.
        catcher?.abandon(reason: CancellationError())
        catcher?.stop()
        catcher = nil
    }

    // MARK: - randomness

    private static func randomBytes(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes)
    }
    private static func randomURLSafe(_ n: Int) -> String { GoogleOAuth.base64url(randomBytes(n)) }
}
