// Ported-From: danwright32/overture mac/Overture/Integration/GmailCredentials.swift @ 0bb3869c8f71777d08712e9fa146fd07c6da699f
// Ported-Adapted: 2eb62f543a41998cdcd04baf9eaf3972671f0e73c358fc0798160d2f9d0bf4de
// Ported-Divergence: danwright32/overture#4035
//
// Ported on 2026-09-19 by backstage#2. Do not edit this copy to fix a fault that is also in
// the origin: fix it there and re-port (L263).
//
// ONE DELIBERATE CHANGE: THE PACKAGE OWNS NO FOLDER. The origin resolved both files inside its own
// app's support folder. A package consumed by three apps cannot, so every path is derived from a
// directory the consumer passes, and there is no default to fall back on. Without that, two apps
// would read and overwrite one another's Google login. The same principle as the no default scope
// list: the package holds no consumer's defaults.
//
// Each read also takes the failure register as a parameter, so a test never touches the one another
// test is using (L2). Everything else is exactly the origin's.
import Foundation

// Loads the OAuth client config (gmail-oauth.json, written outside git) and persists
// the tokens. Tokens live in a 0600 file in Application Support rather than the
// Keychain because the app is ad-hoc signed during development (its code signature
// changes every build, which makes Keychain item ACLs churn and prompt). On a
// single-user Mac a 0600 file is read-only to Dan's account; hardening to the
// Keychain for a stably-signed build is a tracked follow-up.

// What a stored grant actually is, so a consumer can say "connected as X,
// confirmed N days ago" rather than presenting a possibly dead local copy as a
// live authorization (L454).
public struct GmailGrant: Equatable, Sendable {
    public let account: String?
    public let grantedScopes: [String]
    public let obtainedAt: Date?
    public let lastConfirmedAt: Date?
}

// Named GrantState rather than Connection because GmailConnection already exists
// in this package as the live Gmail client: a shared name is read as evidence of
// shared behaviour, and these two are about entirely different things (L263).
//
// Three outcomes rather than a Bool, because a grant that exists but does not
// cover what this consumer asks for is a different fact from no grant at all,
// and they need different remedies: one re-consents for more, the other consents
// for the first time (L11).
public enum GmailGrantState: Equatable, Sendable {
    case notConnected
    case connected(GmailGrant)
    case grantMismatch(missingScopes: [String], storedAccount: String?)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

public struct GmailClient: Codable, Equatable, Sendable {
    public var clientId: String
    public var clientSecret: String

    public init(clientId: String, clientSecret: String) {
        self.clientId = clientId
        self.clientSecret = clientSecret
    }
}

public struct StoredTokens: Codable, Equatable, Sendable {
    public var refreshToken: String
    public var accessToken: String?
    public var accessTokenExpiry: Date?

    // WHAT THIS TOKEN IS ACTUALLY A GRANT FOR (backstage#45).
    //
    // Without these, a token file is adopted by whichever consumer reads it, and
    // the one fact that differs between three apps sharing this package is the
    // scopes they asked for. A token granted for less than a consumer needs then
    // reads as connected and fails at the one call that needs the missing scope,
    // far from the cause.
    //
    // OPTIONAL SO AN OLDER FILE STILL DECODES rather than the reader throwing and
    // a consumer seeing an unreadable store where there is a readable one holding
    // an old shape. A token that records nothing is NOT connected, which is the
    // fail closed direction (L42): it cannot be shown to cover anything.
    public var grantedScopes: [String]?

    // WHO GRANTED IT, and it is nil far more often than it looks. Google returns
    // an identity only when an identity scope was requested, so a consumer asking
    // for gmail.send alone gets no account back. That is a fact worth surfacing
    // rather than a gap to paper over, and it is why the account is RECORDED and
    // shown but never matched on: matching on a value the grant cannot carry
    // would refuse every correct connection.
    public var account: String?

    // WHEN IT WAS OBTAINED, and when it was last exchanged successfully.
    //
    // A local copy of an authorization that lives at Google reads identically
    // whether it is live or dead, and the first action taken on a stale one is
    // what discovers the staleness (L454). With an OAuth client in Testing status
    // the refresh token expires every seven days, so that discovery would
    // otherwise be a real send failing.
    public var obtainedAt: Date?
    public var lastConfirmedAt: Date?

    public init(refreshToken: String, accessToken: String? = nil, accessTokenExpiry: Date? = nil,
                grantedScopes: [String]? = nil, account: String? = nil,
                obtainedAt: Date? = nil, lastConfirmedAt: Date? = nil) {
        self.refreshToken = refreshToken
        self.grantedScopes = grantedScopes
        self.account = account
        self.obtainedAt = obtainedAt
        self.lastConfirmedAt = lastConfirmedAt
        self.accessToken = accessToken
        self.accessTokenExpiry = accessTokenExpiry
    }

    public func isFresh(now: Date, skew: TimeInterval = 120) -> Bool {
        guard let accessToken, !accessToken.isEmpty, let exp = accessTokenExpiry else { return false }
        return now.addingTimeInterval(skew) < exp
    }
}

public enum GmailCredentials {
    public static func clientConfigURL(in directory: URL) -> URL {
        directory.appendingPathComponent("gmail-oauth.json")
    }
    public static func tokenURL(in directory: URL) -> URL {
        directory.appendingPathComponent("gmail-tokens.json")
    }

    public static func loadClient(from url: URL) -> GmailClient? {
        loadClient(from: url, recorder: .shared)
    }

    // Internal, with the register as a parameter so a test can hand it a private one (L2). Which of
    // these failures a consumer can SEE is backstage#12's decision, so the register is not public yet.
    static func loadClient(from url: URL, recorder: HandoffReadFailures) -> GmailClient? {
        // #2879: an unreadable credentials file is not an absent one. Read as absent it says Gmail was
        // never connected, which is a state Dan can act on; what it really means is that the connection
        // he made is unusable, and nothing said so.
        return HandoffFile.read(at: url, recorder: recorder) { try JSONDecoder().decode(GmailClient.self, from: $0) }.value
    }

    public static func loadTokens(from url: URL) -> StoredTokens? {
        loadTokens(from: url, recorder: .shared)
    }

    static func loadTokens(from url: URL, recorder: HandoffReadFailures) -> StoredTokens? {
        return HandoffFile.read(at: url, recorder: recorder) { try JSONDecoder().decode(StoredTokens.self, from: $0) }.value
    }

    // A CREDENTIAL WRITE OR DELETE INSIDE A TEST RUN MUST TARGET A THROWAWAY PATH
    // (backstage#44).
    //
    // backstage#5 put a refusal at the one place a live Gmail call is made, which
    // covers the way IN. These two are the way OUT, they name a path directly, and
    // they are reachable from disconnect(), signalAuthExpired(), persistExchangedTokens
    // and validAccessToken. A seam that keeps a test off live data on the way in does
    // not cover the way out, and the way out is the half that cannot be undone (L201,
    // L5). A consumer cannot fix this from outside, because the write happens below
    // its call site, so the refusal belongs in the service (L2, L196).
    //
    // WHAT COUNTS AS THROWAWAY IS A PARAMETER, defaulting to the system temporary
    // directory, which is where every test here already puts its credentials. It is a
    // parameter because the refusing branch cannot otherwise be driven: proving it
    // would mean a test pointing at a credentials directory somebody owns (L159).
    public struct CredentialWriteRefused: LocalizedError, Equatable {
        public let path: String
        public var errorDescription: String? {
            "A Gmail credential write was refused: this process is a test run and \(path) is not "
            + "under the throwaway directory. A test that reaches here is about to change a real "
            + "Google login, and that cannot be undone. Point it at a temporary directory."
        }
    }

    // The decision alone, so both outcomes can be asserted without writing anything,
    // the same shape GmailNetworking.refusal(underTests:) already uses (L159).
    static func writeRefusal(at url: URL, underTests: Bool,
                             throwaway: URL) -> CredentialWriteRefused? {
        guard underTests else { return nil }
        guard !isUnder(url, throwaway) else { return nil }
        return CredentialWriteRefused(path: url.path)
    }

    // CONTAINMENT BY PATH COMPONENT, NEVER BY STRING PREFIX: a sibling whose name
    // merely begins with the throwaway directory's would pass a prefix test while
    // being somewhere else entirely (L266). Symlinks are resolved first because the
    // system temporary directory is reached through one on macOS, so the two sides
    // would otherwise never agree.
    private static func isUnder(_ url: URL, _ directory: URL) -> Bool {
        let target = url.resolvingSymlinksInPath().standardized.pathComponents
        let root = directory.resolvingSymlinksInPath().standardized.pathComponents
        guard target.count > root.count else { return false }
        return Array(target.prefix(root.count)) == root
    }

    // Goes through SecureFileWrite (#524) so the file is never briefly world-default-readable the
    // way a plain atomic write followed by a separate best-effort chmod would leave it (#486).
    //
    // THROWS ON REFUSAL, RETURNS FALSE ON A FAILED WRITE, and those are different
    // facts (L11): one is a test about to destroy a real login, the other is a disk
    // that would not take the bytes.
    @discardableResult
    // WHETHER THIS IS A TEST RUN IS NOT A PARAMETER, deliberately. A public
    // default argument cannot name an internal symbol anyway, and exposing it
    // would hand a consumer a one word bypass of a refusal that exists to protect
    // them (L42: a control that exists to protect somebody fails closed).
    public static func saveTokens(_ tokens: StoredTokens, to url: URL,
                                  throwaway: URL = FileManager.default.temporaryDirectory) throws -> Bool {
        if let refusal = writeRefusal(at: url, underTests: GmailNetworking.isTestRun(),
                                      throwaway: throwaway) {
            throw refusal
        }
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        return SecureFileWrite.writeOwnerOnly(data, to: url)
    }

    public static func clearTokens(at url: URL,
                                   throwaway: URL = FileManager.default.temporaryDirectory) throws {
        if let refusal = writeRefusal(at: url, underTests: GmailNetworking.isTestRun(),
                                      throwaway: throwaway) {
            throw refusal
        }
        try? FileManager.default.removeItem(at: url)
    }

    // WHAT THIS CONSUMER IS ACTUALLY CONNECTED FOR (backstage#45).
    //
    // `wanting` is the consumer's own scope list, so connected means THESE scopes
    // rather than "a token file exists". Coverage, not equality: a stored grant
    // wider than what is wanted still covers it, and re-consenting over that would
    // ask the person for permission they have already given.
    public static func connection(at url: URL, wanting scopes: [String]) -> GmailGrantState {
        connection(at: url, wanting: scopes, recorder: .shared)
    }

    static func connection(at url: URL, wanting scopes: [String],
                           recorder: HandoffReadFailures) -> GmailGrantState {
        guard let stored = loadTokens(from: url, recorder: recorder),
              !stored.refreshToken.isEmpty else { return .notConnected }
        // A token recording no grant cannot be shown to cover anything, so it is
        // not this consumer's authorization (L42).
        guard let granted = stored.grantedScopes, !granted.isEmpty else { return .notConnected }
        let missing = scopes.filter { !granted.contains($0) }
        guard missing.isEmpty else {
            return .grantMismatch(missingScopes: missing, storedAccount: stored.account)
        }
        return .connected(GmailGrant(account: stored.account, grantedScopes: granted,
                                     obtainedAt: stored.obtainedAt,
                                     lastConfirmedAt: stored.lastConfirmedAt))
    }
}
