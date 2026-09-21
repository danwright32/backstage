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
                         productName: String = "Ovation",
                         loginHint: String? = nil) throws -> GmailAuthManager {
        try GmailAuthManager(credentialsDirectory: dir, scopes: scopes, productName: productName, loginHint: loginHint,
                             now: { [t0] in t0 }, sleep: sleep, fetch: fetch, openBrowser: openBrowser)
    }

    // ---------- backstage#3: the scopes are the consumer's, stated, and never empty ----------

    // Naming NONE does not compile (scripts/test-scopes-required.sh proves that by building a
    // consumer). Naming an EMPTY list compiles, so it is refused here, by name, at construction.
    @Test func anEmptyScopeListIsRefused() throws {
        #expect(throws: GmailAuthManager.AuthError.noScopes) {
            _ = try GmailAuthManager(credentialsDirectory: try scratch(), scopes: [], productName: "Ovation")
        }
    }

    // ---------- the access token ----------

    @Test func aFreshTokenIsReturnedWithoutAsking() async throws {
        let dir = try scratch(); try writeClient(dir)
        _ = try GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt", accessToken: "fresh",
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
        _ = try GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt", accessToken: "old",
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

    // A SUCCESSFUL EXCHANGE IS THE ONLY THING THAT MOVES lastConfirmedAt
    // (backstage#45), because it is the only evidence the grant at Google is
    // still live. A stamp moved by anything else would let a dead credential go
    // on reading as freshly confirmed (L454).
    @Test func asuccessfulRefreshRecordsThatTheGrantIsStillLive() async throws {
        let dir = try scratch(); try writeClient(dir)
        let url = GmailCredentials.tokenURL(in: dir)
        let longAgo = t0.addingTimeInterval(-86_400 * 30)
        _ = try GmailCredentials.saveTokens(
            StoredTokens(refreshToken: "rt", accessToken: "old",
                         accessTokenExpiry: t0.addingTimeInterval(-10),
                         grantedScopes: ["https://www.googleapis.com/auth/gmail.send"],
                         obtainedAt: longAgo, lastConfirmedAt: longAgo), to: url)
        let m = try manager(dir, fetch: { [self] req in
            self.response(200, #"{"access_token":"new","expires_in":3600}"#, req)
        })
        #expect(try await m.validAccessToken() == "new")
        let saved = GmailCredentials.loadTokens(from: url)
        #expect(saved?.lastConfirmedAt == t0)
        #expect(saved?.obtainedAt == longAgo, "when it was first granted does not move")
    }

    // AND A FAILED ONE DOES NOT MOVE IT. A refusal that still refreshed the stamp
    // would report a credential as confirmed by the very exchange that failed.
    @Test func afailedRefreshLeavesTheConfirmationStampWhereItWas() async throws {
        let dir = try scratch(); try writeClient(dir)
        let url = GmailCredentials.tokenURL(in: dir)
        let longAgo = t0.addingTimeInterval(-86_400 * 30)
        _ = try GmailCredentials.saveTokens(
            StoredTokens(refreshToken: "rt", accessTokenExpiry: t0.addingTimeInterval(-10),
                         grantedScopes: ["https://www.googleapis.com/auth/gmail.send"],
                         obtainedAt: longAgo, lastConfirmedAt: longAgo), to: url)
        let m = try manager(dir, fetch: { [self] req in self.response(503, "gateway", req) })
        do { _ = try await m.validAccessToken(); Issue.record("expected a refusal") }
        catch GmailAuthManager.AuthError.refreshFailed { } catch { Issue.record("wrong error \(error)") }
        #expect(GmailCredentials.loadTokens(from: url)?.lastConfirmedAt == longAgo)
    }

    // A dead login clears the saved tokens, so the consumer shows disconnected.
    @Test func aDeadLoginClearsTheTokens() async throws {
        let dir = try scratch(); try writeClient(dir)
        let url = GmailCredentials.tokenURL(in: dir)
        _ = try GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt"), to: url)
        let m = try manager(dir, fetch: { [self] req in self.response(400, #"{"error":"invalid_grant"}"#, req) })
        await #expect(throws: GmailAuthManager.AuthError.authExpired) { _ = try await m.validAccessToken() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // A passing fault must NEVER throw away a saved login that still works.
    @Test func aTemporaryFailureKeepsTheTokens() async throws {
        let dir = try scratch(); try writeClient(dir)
        let url = GmailCredentials.tokenURL(in: dir)
        _ = try GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt"), to: url)
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
        _ = try GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt"), to: GmailCredentials.tokenURL(in: dir))
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

    // ---------- backstage#25: the page claims only what is true when it is shown ----------

    // The tab is answered the moment the CODE arrives, before the exchange and the save, either of
    // which can still fail. So the page may not say the account is connected (L12, L11): here the
    // exchange fails, and the person must not have been told otherwise.
    @Test func theRedirectPageNeverClaimsAConnectionItHasNotMade() async throws {
        let dir = try scratch(); try writeClient(dir)
        let page = Box<String?>(nil)
        let m = try manager(dir,
            fetch: { [self] req in self.response(400, #"{"error":"invalid_grant"}"#, req) },
            openBrowser: { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let state = items.first { $0.name == "state" }?.value ?? ""
                let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
                Task.detached {
                    let got = try? await URLSession(configuration: .ephemeral)
                        .data(from: URL(string: "\(redirect)/?code=c&state=\(state)")!)
                    page.value = got.map { String(decoding: $0.0, as: UTF8.self) } ?? ""
                }
            })
        do { try await m.connect(); Issue.record("expected the exchange to fail") } catch { }
        for _ in 0..<500 where page.value == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let shown = try #require(page.value).lowercased()
        #expect(!shown.contains("connected"), "the tab claimed a connection: \(shown)")
        #expect(shown.contains("return to"), "the tab should send the person back to the app")
    }

    // ---------- backstage#61: the catch is shared, and each way it can end is its own answer ----------

    // Google refusing consent arrives as "no code in redirect", which is what a malformed redirect
    // also says, so the one thing the person needed (Google's own reason) is the one thing thrown
    // away. Distinct causes get distinct messages (L11).
    @Test func aConsentGoogleRefusedCarriesGooglesOwnReason() async throws {
        let dir = try scratch(); try writeClient(dir)
        let m = try manager(dir,
            fetch: { _ in throw URLError(.badURL) },
            openBrowser: { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let state = items.first { $0.name == "state" }?.value ?? ""
                let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
                Task.detached { _ = try? await URLSession(configuration: .ephemeral)
                    .data(from: URL(string: "\(redirect)/?error=access_denied&state=\(state)")!) }
            })
        await #expect(throws: GmailAuthManager.AuthError.consentRefused("access_denied")) {
            try await m.connect()
        }
        #expect(!m.isConnected)
    }

    // The package names no app, so the name in the tab is the consumer's and comes from the
    // consumer. Without it the page can only say "the app", which is every app.
    @Test func theTabNamesTheProductTheConsumerGave() async throws {
        let dir = try scratch(); try writeClient(dir)
        let page = Box<String?>(nil)
        let m = try manager(dir,
            fetch: { [self] req in self.response(400, #"{"error":"invalid_grant"}"#, req) },
            openBrowser: { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let state = items.first { $0.name == "state" }?.value ?? ""
                let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
                Task.detached {
                    let got = try? await URLSession(configuration: .ephemeral)
                        .data(from: URL(string: "\(redirect)/?code=c&state=\(state)")!)
                    page.value = got.map { String(decoding: $0.0, as: UTF8.self) } ?? ""
                }
            },
            productName: "Rehearsal Diary")
        do { try await m.connect(); Issue.record("expected the exchange to fail") } catch { }
        for _ in 0..<500 where page.value == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(try #require(page.value).contains("Rehearsal Diary"),
                "the tab does not say where to go back to")

    }

    // Every way the catch can end has its own answer here. A mapping falling through to one shared
    // error would give two causes one message, which is the defect above in another form (L11).
    @Test func everyWayTheCatchCanEndHasItsOwnAnswer() {
        #expect(GmailAuthManager.authError(for: .stateMismatch) == .stateMismatch)
        #expect(GmailAuthManager.authError(for: .refusedByGoogle("access_denied"))
                == .consentRefused("access_denied"))
        #expect(GmailAuthManager.authError(for: .alreadyWaiting) == .alreadyConnecting)
        if case .exchangeFailed(let why) = GmailAuthManager.authError(for: .timedOut) {
            #expect(why.contains("Timed out"))
        } else { Issue.record("a give up is not reported as one") }
        if case .exchangeFailed(let why) = GmailAuthManager.authError(for: .noCode) {
            #expect(why.contains("no code"))
        } else { Issue.record("a redirect carrying no code is not reported as one") }
    }

    // ---------- backstage#15: a blip and an outage are different events ----------

    private func failingRefresh(_ dir: URL, status: Int = 503, clock: Box<Date>) throws -> GmailAuthManager {
        try writeClient(dir)
        _ = try GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt"), to: GmailCredentials.tokenURL(in: dir))
        let answer = Box(status)
        return try GmailAuthManager(credentialsDirectory: dir, scopes: scopes, productName: "Ovation",
            now: { clock.value },
            fetch: { [self] req in
                answer.value == 200
                    ? self.response(200, #"{"access_token":"at","expires_in":1}"#, req)
                    : self.response(answer.value, "gateway", req)
            })
    }

    @Test func oneTemporaryFailureIsABlipNotAnOutage() async throws {
        let clock = Box(t0)
        let m = try failingRefresh(try scratch(), clock: clock)
        _ = try? await m.validAccessToken()
        #expect(m.refreshHealth.consecutiveTemporaryFailures == 1)
        #expect(m.refreshHealth.failingSince == t0)
        #expect(!m.refreshHealth.isSustained)
    }

    // Three in a row with no success between them is an outage, and it says since WHEN, which is
    // what lets a consumer say "Gmail has not refreshed since 14:02" rather than "try again" for ever.
    @Test func consecutiveTemporaryFailuresBecomeAnOutageNamingWhenItBegan() async throws {
        let clock = Box(t0)
        let m = try failingRefresh(try scratch(), clock: clock)
        for minute in 0..<3 {
            clock.value = t0.addingTimeInterval(TimeInterval(minute * 60))
            _ = try? await m.validAccessToken()
        }
        #expect(m.refreshHealth.consecutiveTemporaryFailures == 3)
        #expect(m.refreshHealth.isSustained)
        #expect(m.refreshHealth.failingSince == t0, "the outage is dated from its FIRST failure")
    }

    @Test func theRunIsResetBySuccessOnTheSameManager() async throws {
        let clock = Box(t0)
        let dir = try scratch(); try writeClient(dir)
        _ = try GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt"), to: GmailCredentials.tokenURL(in: dir))
        let answer = Box(503)
        let m = try GmailAuthManager(credentialsDirectory: dir, scopes: scopes, productName: "Ovation",
            now: { clock.value },
            fetch: { [self] req in
                answer.value == 200 ? self.response(200, #"{"access_token":"at","expires_in":1}"#, req)
                                    : self.response(503, "gateway", req) })
        for _ in 0..<3 { _ = try? await m.validAccessToken() }
        answer.value = 200
        _ = try await m.validAccessToken()
        #expect(m.refreshHealth == .healthy)
    }

    // A dead login is not a temporary failure and must not be counted as one: it has its own state,
    // the cleared tokens, and its own remedy.
    @Test func aDeadLoginIsNotCountedAsATemporaryFailure() async throws {
        let clock = Box(t0)
        let m = try failingRefresh(try scratch(), status: 401, clock: clock)
        _ = try? await m.validAccessToken()
        #expect(m.refreshHealth == .healthy)
    }

    // ---------- the package carries no consumer's voice ----------

    @Test func noMessageNamesAnyApp() throws {
        let all: [GmailAuthManager.AuthError] = [.noClientConfig, .notConnected, .listenerFailed,
            .listenerUnreachable, .stateMismatch, .exchangeFailed("x"), .refreshFailed("x"), .authExpired,
            .tokenSaveFailed, .alreadyConnecting, .noScopes, .consentRefused("x")]
        for e in all {
            let m = (e.errorDescription ?? "").lowercased()
            #expect(!m.contains("overture") && !m.contains("click") && !m.contains("connect gmail"), "\(e): \(m)")
        }
    }
}
