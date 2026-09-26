import Foundation
import Testing
@testable import BackstageGoogle

// The grant recorded is the one GOOGLE made, never the one that was asked for (backstage#68).
//
// Google's granular consent screen lets a person untick a scope. The request list then says more
// than the grant does, and a token recorded against the request reads as connected for a scope it
// does not carry, failing only later at the API call that needs it (L127). So the reply's own
// `scope` is what is stored, on the code exchange and on every refresh, and a reply that says
// nothing about its scope is refused by name rather than read as an empty grant or a full one
// (L215, L506).
@MainActor
struct GrantedScopesTests {

    private let send = "https://www.googleapis.com/auth/gmail.send"
    private let modify = "https://www.googleapis.com/auth/gmail.modify"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backstage-68-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeClient(_ dir: URL) throws {
        try JSONEncoder().encode(GmailClient(clientId: "cid", clientSecret: "sec"))
            .write(to: GmailCredentials.clientConfigURL(in: dir))
    }

    nonisolated private func response(_ status: Int, _ body: String, _ req: URLRequest) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private func manager(_ dir: URL, wanting scopes: [String],
                         fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil) throws -> GmailAuthManager {
        let m = try GmailAuthManager(credentialsDirectory: dir, scopes: scopes, productName: "Ovation",
                                     now: { [t0] in t0 }, fetch: fetch)
        m.throwawayRoot = dir
        return m
    }

    private func tokens(_ json: String) throws -> OAuthTokens {
        try JSONDecoder().decode(OAuthTokens.self, from: Data(json.utf8))
    }

    // ---------- reading the reply ----------

    @Test func theReplysScopeIsReadAsTheSpaceSeparatedListGoogleGranted() throws {
        let t = try tokens(#"{"access_token":"at","scope":"  \#(send)   \#(modify) "}"#)
        #expect(t.grantedScopes == [send, modify])
    }

    // ABSENT IS NOT EMPTY. A reader that turned a missing field into [] would make "Google said
    // nothing" and "Google granted nothing" the same answer (L215).
    @Test func aReplyWithNoScopeFieldHasNoGrantRatherThanAnEmptyOne() throws {
        let t = try tokens(#"{"access_token":"at"}"#)
        #expect(t.grantedScopes == nil)
    }

    // ---------- the code exchange ----------

    // THE CASE THE ISSUE IS ABOUT: a person unticked a scope on the consent screen.
    @Test func aConsentGrantingLessThanWasAskedIsAMismatchNamingTheMissingScope() throws {
        let dir = try scratch()
        let m = try manager(dir, wanting: [send, modify])
        #expect(throws: GmailAuthManager.AuthError.scopesNotGranted([modify])) {
            try m.persistExchangedTokens(OAuthTokens(accessToken: "at", refreshToken: "rt",
                                                     expiresIn: 3600, scope: send))
        }
        guard case .grantMismatch(let missing, _) = m.connection else {
            Issue.record("expected a mismatch, got \(m.connection)"); return
        }
        #expect(missing == [modify])
        #expect(!m.isConnected)
    }

    // A NARROWER CONSENT MUST NOT OVERWRITE A LOGIN THAT ALREADY COVERS EVERYTHING (L5). Unticking a
    // box on a second consent does not revoke the first grant at Google, so the stored one is still
    // good and replacing it would disconnect somebody who was connected.
    @Test func aNarrowerConsentLeavesAnEarlierCoveringLoginInPlace() throws {
        let dir = try scratch()
        let url = GmailCredentials.tokenURL(in: dir)
        let earlier = StoredTokens(refreshToken: "good", grantedScopes: [send, modify],
                                   obtainedAt: t0.addingTimeInterval(-86_400),
                                   lastConfirmedAt: t0.addingTimeInterval(-86_400))
        #expect(try GmailCredentials.saveTokens(earlier, to: url, throwaway: dir))
        let m = try manager(dir, wanting: [send, modify])

        #expect(throws: GmailAuthManager.AuthError.scopesNotGranted([modify])) {
            try m.persistExchangedTokens(OAuthTokens(accessToken: "at", refreshToken: "worse",
                                                     expiresIn: 3600, scope: send))
        }
        #expect(GmailCredentials.loadTokens(from: url) == earlier)
        #expect(m.isConnected)
    }

    @Test func aConsentReplyNamingNoScopeIsRefusedAndSavesNothing() throws {
        let dir = try scratch()
        let m = try manager(dir, wanting: [send])
        #expect(throws: GmailAuthManager.AuthError.grantUnreported) {
            try m.persistExchangedTokens(OAuthTokens(accessToken: "at", refreshToken: "rt", expiresIn: 3600))
        }
        #expect(!FileManager.default.fileExists(atPath: GmailCredentials.tokenURL(in: dir).path))
    }

    // What is stored is Google's list, so a wider grant is recorded as wider rather than trimmed back
    // to the request.
    @Test func whatIsStoredIsGooglesListNotTheRequest() throws {
        let dir = try scratch()
        let m = try manager(dir, wanting: [send])
        try m.persistExchangedTokens(OAuthTokens(accessToken: "at", refreshToken: "rt", expiresIn: 3600,
                                                 scope: "\(send) \(modify)"))
        #expect(GmailCredentials.loadTokens(from: GmailCredentials.tokenURL(in: dir))?.grantedScopes == [send, modify])
    }

    // ---------- every refresh ----------

    private func staleLogin(_ dir: URL, granted: [String]) throws -> StoredTokens {
        try writeClient(dir)
        let stored = StoredTokens(refreshToken: "rt", accessToken: "old",
                                  accessTokenExpiry: t0.addingTimeInterval(-10), grantedScopes: granted,
                                  obtainedAt: t0.addingTimeInterval(-86_400),
                                  lastConfirmedAt: t0.addingTimeInterval(-86_400))
        #expect(try GmailCredentials.saveTokens(stored, to: GmailCredentials.tokenURL(in: dir), throwaway: dir))
        return stored
    }

    @Test func aRefreshRecordsTheScopeGoogleReportsNow() async throws {
        let dir = try scratch()
        _ = try staleLogin(dir, granted: [send])
        let m = try manager(dir, wanting: [send], fetch: { [self, send, modify] req in
            self.response(200, #"{"access_token":"new","expires_in":3600,"scope":"\#(send) \#(modify)"}"#, req)
        })
        #expect(try await m.validAccessToken() == "new")
        #expect(GmailCredentials.loadTokens(from: GmailCredentials.tokenURL(in: dir))?.grantedScopes == [send, modify])
    }

    // A grant narrowed at Google since it was stored (a scope removed in the account's settings) is
    // what the refresh reports, so the stored record follows it and the manager says what is missing.
    @Test func aRefreshReportingLessThanIsWantedIsRecordedAndRefused() async throws {
        let dir = try scratch()
        _ = try staleLogin(dir, granted: [send, modify])
        let m = try manager(dir, wanting: [send, modify], fetch: { [self, send] req in
            self.response(200, #"{"access_token":"new","expires_in":3600,"scope":"\#(send)"}"#, req)
        })
        await #expect(throws: GmailAuthManager.AuthError.scopesNotGranted([modify])) {
            _ = try await m.validAccessToken()
        }
        guard case .grantMismatch(let missing, _) = m.connection else {
            Issue.record("expected a mismatch, got \(m.connection)"); return
        }
        #expect(missing == [modify])
    }

    // A refresh reply that says nothing about its scope is not evidence the grant is still what it
    // was, so it confirms nothing and saves nothing.
    @Test func aRefreshReplyNamingNoScopeIsRefusedAndChangesNothing() async throws {
        let dir = try scratch()
        let before = try staleLogin(dir, granted: [send])
        let m = try manager(dir, wanting: [send], fetch: { [self] req in
            self.response(200, #"{"access_token":"new","expires_in":3600}"#, req)
        })
        await #expect(throws: GmailAuthManager.AuthError.grantUnreported) { _ = try await m.validAccessToken() }
        #expect(GmailCredentials.loadTokens(from: GmailCredentials.tokenURL(in: dir)) == before)
    }
}
