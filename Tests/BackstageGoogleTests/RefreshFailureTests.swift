import Foundation
import Testing
@testable import BackstageGoogle

// How a token refresh FAILS, which is the half of this code that decides whether
// a person is asked to sign in again. backstage#2.
//
// This is error path behaviour and it is worth more than the happy path: the
// costly direction is treating a passing blip as a dead login, because that
// throws away a saved connection that was working and makes somebody
// reauthorize for nothing. So every case that is NOT a proven dead login has to
// come back transient.
struct RefreshFailureTests {

    private func body(_ s: String) -> Data { Data(s.utf8) }

    @Test func aGoodResponseYieldsTokens() throws {
        let data = body(#"{"access_token":"at","refresh_token":"rt","expires_in":3599}"#)
        let result = GoogleOAuth.interpretRefreshResponse(status: 200, data: data)
        let tokens = try #require(try? result.get())
        #expect(tokens.accessToken == "at")
        #expect(tokens.refreshToken == "rt")
        #expect(tokens.expiresIn == 3599)
    }

    // A revoked or expired refresh token. Google says this with a 400 carrying
    // invalid_grant, and it is the one case where the saved login really is dead.
    @Test func invalidGrantIsADeadLogin() {
        let result = GoogleOAuth.interpretRefreshResponse(
            status: 400, data: body(#"{"error":"invalid_grant"}"#))
        #expect(result == .failure(.authExpired))
    }

    @Test func unauthorizedIsADeadLogin() {
        let result = GoogleOAuth.interpretRefreshResponse(status: 401, data: body("nope"))
        #expect(result == .failure(.authExpired))
    }

    // A 400 that is NOT invalid_grant must not be read as a dead login. The two
    // arrive with the same status code, so the body is the only thing that tells
    // them apart, and getting this wrong signs somebody out over a bad request.
    @Test func otherBadRequestsAreTransient() {
        let result = GoogleOAuth.interpretRefreshResponse(
            status: 400, data: body(#"{"error":"rate_limit_exceeded"}"#))
        #expect(result == .failure(.transient))
    }

    @Test func serverErrorsAreTransient() {
        let result = GoogleOAuth.interpretRefreshResponse(status: 503, data: body("gateway"))
        #expect(result == .failure(.transient))
    }

    // THE ONE THAT IS EASIEST TO GET WRONG: a 200 whose body cannot be read.
    // Nothing is known about the login from it, and "we do not know" must never
    // become "it is dead", because that is the direction that costs a working
    // connection (L93).
    @Test func aSuccessWithAnUnreadableBodyIsTransientNeverDead() {
        for junk in ["", "not json at all", "{}", #"{"access_token":123}"#] {
            let result = GoogleOAuth.interpretRefreshResponse(status: 200, data: body(junk))
            #expect(result == .failure(.transient), "body \(junk.isEmpty ? "<empty>" : junk)")
        }
    }

    // The request builders. Form encoded, and the PKCE verifier has to be in the
    // exchange or Google refuses it.
    @Test func theExchangeCarriesTheVerifier() throws {
        let config = OAuthConfig(clientId: "cid", clientSecret: "sec",
                                 redirectURI: "http://127.0.0.1:1", scopes: ["s"])
        let request = GoogleOAuth.tokenExchangeRequest(
            config: config, code: "the-code", pkce: PKCE(verifier: "ver", challenge: "ch"))

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let sent = String(data: try #require(request.httpBody), encoding: .utf8) ?? ""
        #expect(sent.contains("code_verifier=ver"))
        #expect(sent.contains("code=the-code"))
        #expect(sent.contains("grant_type=authorization_code"))
    }

    @Test func theRefreshAsksForARefresh() throws {
        let config = OAuthConfig(clientId: "cid", clientSecret: "sec",
                                 redirectURI: "http://127.0.0.1:1", scopes: ["s"])
        let request = GoogleOAuth.refreshRequest(config: config, refreshToken: "rt")
        let sent = String(data: try #require(request.httpBody), encoding: .utf8) ?? ""
        #expect(sent.contains("grant_type=refresh_token"))
        #expect(sent.contains("refresh_token=rt"))
        // The verifier belongs to the exchange alone; sending it here would be a
        // PKCE value travelling where it has no business being.
        #expect(!sent.contains("code_verifier"))
    }
}
