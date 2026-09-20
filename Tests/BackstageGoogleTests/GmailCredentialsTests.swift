import Foundation
import Testing
@testable import BackstageGoogle

// Where the OAuth client and the tokens live, and how they are written. backstage#2.
//
// THE PACKAGE OWNS NO FOLDER. The origin resolved these paths inside its own app's support folder.
// A package consumed by three apps cannot, so every path here is derived from a directory the
// consumer passes, and there is no default for it to fall back on.
struct GmailCredentialsTests {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backstage-creds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func pathsAreDerivedFromTheDirectoryTheConsumerGives() throws {
        let dir = try scratch()
        #expect(GmailCredentials.clientConfigURL(in: dir) == dir.appendingPathComponent("gmail-oauth.json"))
        #expect(GmailCredentials.tokenURL(in: dir) == dir.appendingPathComponent("gmail-tokens.json"))
    }

    @Test func tokensRoundTrip() throws {
        let url = GmailCredentials.tokenURL(in: try scratch())
        // The grant travels with the token now (backstage#45), so the round trip
        // has to carry it or the reading below is not the one consumers get.
        let tokens = StoredTokens(refreshToken: "rt", accessToken: "at",
                                  accessTokenExpiry: Date(timeIntervalSince1970: 2_000_000_000),
                                  grantedScopes: ["https://www.googleapis.com/auth/gmail.send"])
        #expect(try GmailCredentials.saveTokens(tokens, to: url))
        #expect(GmailCredentials.loadTokens(from: url, recorder: HandoffReadFailures()) == tokens)
        #expect(GmailCredentials.connection(at: url,
                                            wanting: ["https://www.googleapis.com/auth/gmail.send"],
                                            recorder: HandoffReadFailures()).isConnected)
    }

    // Written owner only, and never visible at wider permissions even for an instant (the origin's
    // #486 and #524): the file holds a refresh token, which is a standing login.
    @Test func theTokenFileIsOwnerOnlyAndLeavesNoTempBehind() throws {
        let dir = try scratch()
        let url = GmailCredentials.tokenURL(in: dir)
        #expect(try GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt"), to: url))

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".tmp-") }
        #expect(leftovers.isEmpty)
    }

    @Test func noTokenFileMeansNotConnected() throws {
        let url = GmailCredentials.tokenURL(in: try scratch())
        let recorder = HandoffReadFailures()
        #expect(GmailCredentials.loadTokens(from: url, recorder: recorder) == nil)
        #expect(GmailCredentials.connection(at: url, wanting: ["any"], recorder: recorder) == .notConnected)
        #expect(recorder.current().isEmpty, "an absent file is the ordinary state and is not a failure")
    }

    // A connection that exists but cannot be read is NOT "never connected". The caller still gets
    // nil, because it cannot use the tokens either way, but the failure has a record (origin #2879).
    @Test func anUnreadableTokenFileIsRecordedRatherThanReadAsNeverConnected() throws {
        let url = GmailCredentials.tokenURL(in: try scratch())
        try Data("corrupt".utf8).write(to: url)
        let recorder = HandoffReadFailures()
        #expect(GmailCredentials.loadTokens(from: url, recorder: recorder) == nil)
        #expect(recorder.current().map(\.file) == ["gmail-tokens.json"])
    }

    @Test func anEmptyRefreshTokenIsNotAConnection() throws {
        let url = GmailCredentials.tokenURL(in: try scratch())
        #expect(try GmailCredentials.saveTokens(StoredTokens(refreshToken: ""), to: url))
        #expect(GmailCredentials.connection(at: url, wanting: ["any"],
                                            recorder: HandoffReadFailures()) == .notConnected)
    }

    @Test func clearingRemovesTheTokens() throws {
        let url = GmailCredentials.tokenURL(in: try scratch())
        #expect(try GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt"), to: url))
        try GmailCredentials.clearTokens(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // Freshness allows a skew, so a token about to expire is refreshed BEFORE Google refuses it.
    @Test func freshnessHonoursTheSkew() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expiring = StoredTokens(refreshToken: "rt", accessToken: "at", accessTokenExpiry: now.addingTimeInterval(60))
        let fine = StoredTokens(refreshToken: "rt", accessToken: "at", accessTokenExpiry: now.addingTimeInterval(600))
        let noAccess = StoredTokens(refreshToken: "rt", accessToken: nil, accessTokenExpiry: now.addingTimeInterval(600))
        #expect(!expiring.isFresh(now: now))
        #expect(fine.isFresh(now: now))
        #expect(!noAccess.isFresh(now: now))
    }
}
