// Ported-From: danwright32/overture mac/Overture/Integration/GmailCredentials.swift @ 0bb3869c8f71777d08712e9fa146fd07c6da699f
// Ported-Adapted: 8d1be4c690663324188ef97e94188eaf92445ea67d63f9242b978749f113878f
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

    public init(refreshToken: String, accessToken: String? = nil, accessTokenExpiry: Date? = nil) {
        self.refreshToken = refreshToken
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

    // Goes through SecureFileWrite (#524) so the file is never briefly world-default-readable the
    // way a plain atomic write followed by a separate best-effort chmod would leave it (#486).
    @discardableResult
    public static func saveTokens(_ tokens: StoredTokens, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        return SecureFileWrite.writeOwnerOnly(data, to: url)
    }

    public static func clearTokens(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public static func isConnected(tokensAt url: URL) -> Bool {
        isConnected(tokensAt: url, recorder: .shared)
    }

    static func isConnected(tokensAt url: URL, recorder: HandoffReadFailures) -> Bool {
        loadTokens(from: url, recorder: recorder)?.refreshToken.isEmpty == false
    }
}
