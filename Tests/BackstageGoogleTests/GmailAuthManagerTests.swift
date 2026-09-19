import Foundation
import Testing
@testable import BackstageGoogle

// The OAuth desktop flow and the access token it vends. backstage#2 step 4b, #3, #5, #13.
//
// Every outside dependency is injected: the network fetch, the browser, the clock and the sleep, so
// no test reaches Google, opens a browser or waits for real (L2, L524). The one real thing is the
// loopback listener on 127.0.0.1, which touches nothing outside this machine.
@MainActor
struct GmailAuthManagerTests {

    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backstage-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let scopes = ["https://www.googleapis.com/auth/gmail.send"]
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func writeClient(_ dir: URL) throws {
        try JSONEncoder().encode(GmailClient(clientId: "cid", clientSecret: "sec"))
            .write(to: GmailCredentials.clientConfigURL(in: dir))
    }

    nonisolated private func response(_ status: Int, _ body: String, _ req: URLRequest) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private func manager(_ dir: URL, fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
                         openBrowser: (@MainActor (URL) -> Void)? = nil,
                         sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil,
                         loginHint: String? = nil) throws -> GmailAuthManager {
        try GmailAuthManager(credentialsDirectory: dir, scopes: scopes, loginHint: loginHint,
                             now: { [t0] in t0 }, sleep: sleep, fetch: fetch, openBrowser: openBrowser)
    }

    // ---------- backstage#3: the scopes are the consumer's, stated, and never empty ----------

    // Naming NONE does not compile (scripts/test-scopes-required.sh proves that by building a
    // consumer). Naming an EMPTY list compiles, so it is refused here, by name, at construction.
    @Test func anEmptyScopeListIsRefused() throws {
        #expect(throws: GmailAuthManager.AuthError.noScopes) {
            _ = try GmailAuthManager(credentialsDirectory: try scratch(), scopes: [])
        }
    }

    // ---------- the access token ----------

    @Test func aFreshTokenIsReturnedWithoutAsking() async throws {
        let dir = try scratch(); try writeClient(dir)
        _ = GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt", accessToken: "fresh",
                                                     accessTokenExpiry: t0.addingTimeInterval(3600)),
                                        to: GmailCredentials.tokenURL(in: dir))
        let asked = Box(0)
        let m = try manager(dir, fetch: { _ in asked.value += 1; throw URLError(.badURL) })
        #expect(try await m.validAccessToken() == "fresh")
        #expect(asked.value == 0)
    }

    @Test func aStaleTokenIsRefreshedAndSavedWithItsNewExpiry() async throws {
        let dir = try scratch(); try writeClient(dir)
        let url = GmailCredentials.tokenURL(in: dir)
        _ = GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt", accessToken: "old",
                                                     accessTokenExpiry: t0.addingTimeInterval(-10)), to: url)
        let m = try manager(dir, fetch: { [self] req in
            self.response(200, #"{"access_token":"new","expires_in":3600}"#, req)
        })
        #expect(try await m.validAccessToken() == "new")
        let saved = GmailCredentials.loadTokens(from: url)
        #expect(saved?.accessToken == "new")
        #expect(saved?.refreshToken == "rt")
        #expect(saved?.accessTokenExpiry == t0.addingTimeInterval(3600))
    }

    // A dead login clears the saved tokens, so the consumer shows disconnected.
    @Test func aDeadLoginClearsTheTokens() async throws {
        let dir = try scratch(); try writeClient(dir)
        let url = GmailCredentials.tokenURL(in: dir)
        _ = GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt"), to: url)
        let m = try manager(dir, fetch: { [self] req in self.response(400, #"{"error":"invalid_grant"}"#, req) })
        await #expect(throws: GmailAuthManager.AuthError.authExpired) { _ = try await m.validAccessToken() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // A passing fault must NEVER throw away a saved login that still works.
    @Test func aTemporaryFailureKeepsTheTokens() async throws {
        let dir = try scratch(); try writeClient(dir)
        let url = GmailCredentials.tokenURL(in: dir)
        _ = GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt"), to: url)
        let m = try manager(dir, fetch: { [self] req in self.response(503, "gateway", req) })
        do { _ = try await m.validAccessToken(); Issue.record("expected a refusal") }
        catch GmailAuthManager.AuthError.refreshFailed { } catch { Issue.record("wrong error \(error)") }
        #expect(GmailCredentials.loadTokens(from: url)?.refreshToken == "rt")
    }

    @Test func noClientConfigAndNoTokensAreTheirOwnAnswers() async throws {
        let dir = try scratch()
        let m = try manager(dir, fetch: { _ in throw URLError(.badURL) })
        await #expect(throws: GmailAuthManager.AuthError.noClientConfig) { _ = try await m.validAccessToken() }
        try writeClient(dir)
        await #expect(throws: GmailAuthManager.AuthError.notConnected) { _ = try await m.validAccessToken() }
    }

    // ---------- saving what the consent produced ----------

    @Test func aConsentWithNoRefreshTokenIsRefused() throws {
        let m = try manager(try scratch())
        do { try m.persistExchangedTokens(OAuthTokens(accessToken: "at", refreshToken: nil, expiresIn: 60)); Issue.record("expected refusal") }
        catch GmailAuthManager.AuthError.exchangeFailed { } catch { Issue.record("wrong error \(error)") }
    }

    // The person has just seen Google's consent screen, so a save that fails must say so.
    @Test func aSaveThatFailsSaysSo() throws {
        let dir = try scratch()
        // The credentials directory is a FILE, so nothing can be written inside it.
        let blocked = dir.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocked)
        let m = try manager(blocked)
        #expect(throws: GmailAuthManager.AuthError.tokenSaveFailed) {
            try m.persistExchangedTokens(OAuthTokens(accessToken: "at", refreshToken: "rt", expiresIn: 60))
        }
    }

    // ---------- backstage#5: a test run can never open a browser or reach Google ----------

    @Test func connectingWithTheRealBrowserRefusesInsideATestRun() async throws {
        let dir = try scratch(); try writeClient(dir)
        let m = try manager(dir)   // no browser and no fetch injected: both are the live ones
        await #expect(throws: GmailNetworking.RefusedUnderTests.self) { try await m.connect() }
    }

    @Test func refreshingThroughTheLiveNetworkRefusesInsideATestRun() async throws {
        let dir = try scratch(); try writeClient(dir)
        _ = GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt"), to: GmailCredentials.tokenURL(in: dir))
        let m = try manager(dir)
        await #expect(throws: GmailNetworking.RefusedUnderTests.self) { _ = try await m.validAccessToken() }
    }

    // ---------- the whole consent flow, on this machine only ----------

    // The browser is faked: it reads the consent URL and plays Google's redirect back to the real
    // loopback listener. The exchange is faked. Everything between is the real code.
    @Test func aCompleteConsentSavesTheTokensAndAsksOnlyForTheNamedScopes() async throws {
        let dir = try scratch(); try writeClient(dir)
        let opened = Box<URL?>(nil)
        let m = try manager(dir,
            fetch: { [self] req in self.response(200, #"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#, req) },
            openBrowser: { url in
                opened.value = url
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let state = items.first { $0.name == "state" }?.value ?? ""
                let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
                Task.detached { _ = try? await URLSession(configuration: .ephemeral)
                    .data(from: URL(string: "\(redirect)/?code=the-code&state=\(state)")!) }
            },
            loginHint: "someone@example.com")
        try await m.connect()

        let items = URLComponents(url: try #require(opened.value), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "scope" }?.value == scopes.joined(separator: " "))
        #expect(items.first { $0.name == "login_hint" }?.value == "someone@example.com")
        #expect(items.first { $0.name == "redirect_uri" }?.value?.hasPrefix("http://127.0.0.1:") == true)
        #expect(GmailCredentials.loadTokens(from: GmailCredentials.tokenURL(in: dir))?.refreshToken == "rt")
        #expect(m.isConnected)
    }

    // The package names no account: with no hint given, none is sent.
    @Test func noHintMeansNoAccountIsPrefilled() async throws {
        let dir = try scratch(); try writeClient(dir)
        let opened = Box<URL?>(nil)
        let m = try manager(dir,
            fetch: { [self] req in self.response(200, #"{"access_token":"at","refresh_token":"rt"}"#, req) },
            openBrowser: { url in
                opened.value = url
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let state = items.first { $0.name == "state" }?.value ?? ""
                let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
                Task.detached { _ = try? await URLSession(configuration: .ephemeral)
                    .data(from: URL(string: "\(redirect)/?code=c&state=\(state)")!) }
            })
        try await m.connect()
        let items = URLComponents(url: try #require(opened.value), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!items.contains { $0.name == "login_hint" })
    }

    // A redirect whose state does not match the request is refused and saves nothing.
    @Test func aRedirectWithTheWrongStateIsRefused() async throws {
        let dir = try scratch(); try writeClient(dir)
        let m = try manager(dir,
            fetch: { _ in throw URLError(.badURL) },
            openBrowser: { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
                Task.detached { _ = try? await URLSession(configuration: .ephemeral)
                    .data(from: URL(string: "\(redirect)/?code=c&state=forged")!) }
            })
        await #expect(throws: GmailAuthManager.AuthError.stateMismatch) { try await m.connect() }
        #expect(!m.isConnected)
    }

    // backstage#13: the give up is driven by the injected sleep, so a redirect that never arrives
    // fails at once here rather than after ninety real seconds.
    @Test func aRedirectThatNeverArrivesGivesUpOnTheInjectedClock() async throws {
        let dir = try scratch(); try writeClient(dir)
        let m = try manager(dir, fetch: { _ in throw URLError(.badURL) },
                            openBrowser: { _ in },
                            sleep: { seconds in
                                // The give up window returns at once; every other wait (the heartbeat)
                                // parks, so the only thing that can end this test is the give up.
                                if seconds >= 60 { return }
                                try await Task.sleep(nanoseconds: 3_600_000_000_000)
                            })
        do { try await m.connect(); Issue.record("expected a give up") }
        catch GmailAuthManager.AuthError.exchangeFailed(let why) { #expect(why.contains("Timed out")) }
        catch { Issue.record("wrong error \(error)") }
    }

    // A second connect while one is in flight is refused rather than tearing down the live listener.
    @Test func aSecondConnectWhileOneIsInFlightIsRefused() throws {
        let m = try manager(try scratch())
        #expect(m.beginConnectAttempt())
        #expect(!m.beginConnectAttempt())
        m.endConnectAttempt()
        #expect(m.beginConnectAttempt())
    }

    // ---------- the package carries no consumer's voice ----------

    @Test func noMessageNamesAnyApp() {
        let all: [GmailAuthManager.AuthError] = [.noClientConfig, .notConnected, .listenerFailed,
            .listenerUnreachable, .stateMismatch, .exchangeFailed("x"), .refreshFailed("x"), .authExpired,
            .tokenSaveFailed, .alreadyConnecting, .noScopes]
        for e in all {
            let m = (e.errorDescription ?? "").lowercased()
            #expect(!m.contains("overture") && !m.contains("click") && !m.contains("connect gmail"), "\(e): \(m)")
        }
    }
}
