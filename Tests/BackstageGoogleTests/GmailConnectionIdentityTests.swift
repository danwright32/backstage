import Foundation
import Testing
@testable import BackstageGoogle

// Connected means THESE scopes, and says who and when (backstage#45).
//
// A bare "a token file exists" test adopts whatever sits at that path as this
// consumer's own authorization: a token from a different account, from an
// earlier build, or granted for a different set of scopes. A write that skips
// because its destination exists must verify the destination holds what it
// expects (L421). And a local copy of an authorization that lives at Google
// reads identically whether it is live or dead, so it has to say when it was
// last confirmed (L454).
struct GmailConnectionIdentityTests {

    private let send = "https://www.googleapis.com/auth/gmail.send"
    private let readonly = "https://www.googleapis.com/auth/gmail.readonly"

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backstage-45-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ tokens: StoredTokens, into dir: URL) throws {
        #expect(try GmailCredentials.saveTokens(tokens, to: GmailCredentials.tokenURL(in: dir),
                                                throwaway: dir))
    }

    @Test func aGrantCoveringWhatIsWantedIsConnected() throws {
        let dir = try scratch()
        let obtained = Date(timeIntervalSince1970: 1_000)
        try write(StoredTokens(refreshToken: "rt", grantedScopes: [send], account: "dan@example.com",
                               obtainedAt: obtained, lastConfirmedAt: obtained), into: dir)

        let state = GmailCredentials.connection(at: GmailCredentials.tokenURL(in: dir), wanting: [send])
        guard case .connected(let grant) = state else {
            Issue.record("expected connected, got \(state)"); return
        }
        #expect(grant.account == "dan@example.com")
        #expect(grant.grantedScopes == [send])
        #expect(grant.obtainedAt == obtained)
    }

    // THE CASE THE ISSUE IS ABOUT. A token granted for less than this consumer
    // asks for is not this consumer's authorization, and proceeding on it fails
    // later at the one call that needs the missing scope, far from the cause.
    @Test func aGrantMissingAScopeIsNotConnectedAndNamesWhatIsMissing() throws {
        let dir = try scratch()
        try write(StoredTokens(refreshToken: "rt", grantedScopes: [send]), into: dir)

        let state = GmailCredentials.connection(at: GmailCredentials.tokenURL(in: dir),
                                                wanting: [send, readonly])
        guard case .grantMismatch(let missing, _) = state else {
            Issue.record("expected a mismatch, got \(state)"); return
        }
        #expect(missing == [readonly])
    }

    // A WIDER GRANT STILL COVERS A NARROWER WANT. The rule is coverage, not
    // equality: re-consenting because the stored grant is broader would ask the
    // person for permission they have already given.
    @Test func aWiderGrantCoversANarrowerWant() throws {
        let dir = try scratch()
        try write(StoredTokens(refreshToken: "rt", grantedScopes: [send, readonly]), into: dir)
        let state = GmailCredentials.connection(at: GmailCredentials.tokenURL(in: dir), wanting: [send])
        #expect(state.isConnected)
    }

    // FAIL CLOSED ON A TOKEN THAT RECORDS NOTHING (L42). A file written before
    // grants were recorded cannot be shown to cover anything, so it is not
    // connected and the person re-consents. The cost is one consent; the
    // alternative is adopting an unknown grant as this consumer's own.
    @Test func aTokenRecordingNoScopesIsNotConnected() throws {
        let dir = try scratch()
        try write(StoredTokens(refreshToken: "rt"), into: dir)
        let state = GmailCredentials.connection(at: GmailCredentials.tokenURL(in: dir), wanting: [send])
        #expect(!state.isConnected)
    }

    @Test func noTokenFileAtAllIsNotConnected() throws {
        let dir = try scratch()
        let state = GmailCredentials.connection(at: GmailCredentials.tokenURL(in: dir), wanting: [send])
        #expect(state == .notConnected)
    }

    @Test func anEmptyRefreshTokenIsNotConnected() throws {
        let dir = try scratch()
        try write(StoredTokens(refreshToken: "", grantedScopes: [send]), into: dir)
        let state = GmailCredentials.connection(at: GmailCredentials.tokenURL(in: dir), wanting: [send])
        #expect(state == .notConnected)
    }

    // A FILE WRITTEN BEFORE THESE FIELDS EXISTED MUST STILL DECODE, rather than
    // the reader throwing and a consumer seeing an unreadable store where there
    // is a readable one holding an old shape.
    @Test func aTokenFileWithOnlyTheOldFieldsStillDecodes() throws {
        let dir = try scratch()
        let url = GmailCredentials.tokenURL(in: dir)
        try #"{"refreshToken":"rt","accessToken":"at"}"#.write(to: url, atomically: true, encoding: .utf8)
        let loaded = GmailCredentials.loadTokens(from: url)
        #expect(loaded?.refreshToken == "rt")
        #expect(loaded?.grantedScopes == nil)
    }

    // --- what the manager records when it actually obtains a grant ---

    @Test @MainActor func afirstExchangeRecordsTheScopesItAskedForAndWhen() throws {
        let dir = try scratch()
        let clock = Date(timeIntervalSince1970: 5_000)
        let manager = try GmailAuthManager(credentialsDirectory: dir, scopes: [send],
                                           productName: "Ovation", now: { clock })
        manager.throwawayRoot = dir

        try manager.persistExchangedTokens(OAuthTokens(accessToken: "at", refreshToken: "rt",
                                                       expiresIn: 3600))

        let stored = GmailCredentials.loadTokens(from: GmailCredentials.tokenURL(in: dir))
        #expect(stored?.grantedScopes == [send])
        #expect(stored?.obtainedAt == clock)
        #expect(stored?.lastConfirmedAt == clock)
    }

    // --- who granted it, when Google says so ---
    //
    // The identity is read from the id token Google returns, and it is returned
    // ONLY when an identity scope was requested. So every case here is about
    // being honest when it is absent, which is the common case: a consumer asking
    // for gmail.send alone never receives one.

    @Test func theAccountIsReadFromTheIdTokensEmailClaim() {
        // A real shaped id token: three dot separated base64url segments. Only the
        // middle one is read, and its signature is deliberately not checked,
        // because this arrives on our own connection to Google's token endpoint.
        let tokens = OAuthTokens(accessToken: "at", refreshToken: "rt", expiresIn: 3600,
                                 idToken: "header.eyJlbWFpbCI6ICJkYW5AZXhhbXBsZS5jb20iLCAic3ViIjogIjEyMyJ9.signature")
        #expect(tokens.account == "dan@example.com")
    }

    @Test func noIdTokenMeansNoAccountRatherThanAGuess() {
        let tokens = OAuthTokens(accessToken: "at", refreshToken: "rt", expiresIn: 3600)
        #expect(tokens.account == nil)
    }

    // A MALFORMED ONE IS NIL, NOT A CRASH. This value is never load bearing: it
    // labels a grant and authorises nothing, so the failure to read it must not
    // take the sign in with it.
    @Test func aMalformedIdTokenIsNoAccountAndDoesNotTrap() {
        for bad in ["", "onlyonesegment", "two.segments", "a.!!!not base64!!!.c", "a.YWJj.c"] {
            let tokens = OAuthTokens(accessToken: "at", refreshToken: "rt", expiresIn: 3600,
                                     idToken: bad)
            #expect(tokens.account == nil, "id token \(bad) must not yield an account")
        }
    }
}
