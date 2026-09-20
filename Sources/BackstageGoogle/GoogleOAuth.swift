// Ported-From: danwright32/overture mac/Overture/Integration/GoogleOAuth.swift @ 750464734bffc8bd0af69898b13ec3e42d233c02
// Ported-Adapted: 17a3d9560022ebcc890c6d5a14e7de64bfb2b9272bb4a7261d3b0e2e956dbd13
//
// Ported on 2026-09-18 by backstage#2. Do not edit this copy to fix a fault
// that is also in the origin: fix it there and re-port (L263).
//
// TWO DELIBERATE CHANGES FROM THE ORIGIN, both recorded rather than silent.
//
// 1. `OAuthConfig.gmailScopes` IS GONE (backstage#3). The origin ships a ready
//    made list of three scopes, including gmail.settings.basic, which it needs
//    to fetch a styled signature and Ovation does not need at all. A list sitting
//    in the package is a list consumers reach for, and an over broad permission is
//    invisible because the code never attempts what it is not meant to do, while a
//    missing one fails loudly on the first run (L503, L124). `scopes` has no
//    default and no memberwise shortcut, so a consumer that names none does not
//    compile.
//
// 2. A DEAD LOGIN IS READ FROM GOOGLE'S `error` FIELD, not from the word
//    appearing anywhere in the body. This one is a FIX, and the origin has it
//    too, so it is tracked there rather than only here. Seen to fail: a 400
//    whose error is rate_limit_exceeded and whose description quotes
//    invalid_grant was read as a dead login, which sends somebody round the
//    whole consent flow over a request that was merely refused.
//
// 3. The consumer facing types and functions are `public`. The origin is one app,
//    so everything was internal. Only what a consumer must name is public;
//    ResponseBody beside this file stays internal.

import Foundation
import CryptoKit

// Constructs the OAuth 2.0 desktop-app flow for Gmail (loopback redirect + PKCE, the
// path Google recommends for native apps). Pure request/URL construction so it is
// testable without the network; the live browser+loopback dance and token storage
// live in GmailAuthManager (built once Dan provides credentials).

public struct OAuthConfig: Equatable, Sendable {
    public var clientId: String
    public var clientSecret: String
    public var redirectURI: String   // http://127.0.0.1:<port> (loopback)
    // NO DEFAULT, and no ready made list to reach for. See the note above.
    public var scopes: [String]

    public init(clientId: String, clientSecret: String, redirectURI: String, scopes: [String]) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

}

public struct PKCE: Equatable, Sendable {
    public var verifier: String
    public var challenge: String   // S256(verifier)

    public init(verifier: String, challenge: String) {
        self.verifier = verifier
        self.challenge = challenge
    }
}

public enum GoogleOAuth {
    static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    // PKCE: a random verifier and its SHA-256 challenge, both base64url (no padding).
    public static func makePKCE(verifierBytes: Data) -> PKCE {
        let verifier = base64url(verifierBytes)
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        return PKCE(verifier: verifier, challenge: challenge)
    }

    // The consent URL the app opens in the browser. `access_type=offline` +
    // `prompt=consent` so Google returns a refresh token.
    public static func authorizationURL(config: OAuthConfig, pkce: PKCE, state: String, loginHint: String? = nil) -> URL {
        var c = URLComponents(string: authEndpoint)!
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: config.clientId),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: config.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        // Pin the account so a browser signed into multiple Google accounts doesn't
        // stall the consent (the authuser=N confusion).
        if let loginHint { items.append(.init(name: "login_hint", value: loginHint)) }
        c.queryItems = items
        return c.url!
    }

    // Exchanges the authorization code for tokens (includes the verifier for PKCE).
    public static func tokenExchangeRequest(config: OAuthConfig, code: String, pkce: PKCE) -> URLRequest {
        formPost(to: tokenEndpoint, fields: [
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "code": code,
            "code_verifier": pkce.verifier,
            "grant_type": "authorization_code",
            "redirect_uri": config.redirectURI,
        ])
    }

    // Trades the long-lived refresh token for a fresh access token.
    public static func refreshRequest(config: OAuthConfig, refreshToken: String) -> URLRequest {
        formPost(to: tokenEndpoint, fields: [
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
    }

    // Why a refresh failed: a dead login Dan must fix vs. a passing blip to retry (#50).
    public enum RefreshFailure: Error, Equatable, Sendable { case authExpired, transient }

    // Reads a token-refresh response. invalid_grant (revoked/expired refresh token) or
    // 401 means reconnect; any other non-success, or a 200 we can't parse, is transient
    // so a still-valid saved login is never thrown away over a blip.
    public static func interpretRefreshResponse(status: Int, data: Data) -> Result<OAuthTokens, RefreshFailure> {
        if status == 200,
           let tokens = ResponseBody.decode(OAuthTokens.self, from: data,
                                            endpoint: "google.oauth.token").value {
            return .success(tokens)
        }
        // A THIRD DELIBERATE CHANGE FROM THE ORIGIN, and it is a fix rather than
        // an adaptation, so it is tracked at the origin too (see the header).
        //
        // The origin asks whether the raw body CONTAINS "invalid_grant". Google
        // returns a JSON object whose `error` is the machine readable code and
        // whose `error_description` is prose, and prose can quote a code it is
        // not reporting. A substring of the whole body reads both the same way.
        //
        // It fails in the COSTLY direction: a request that was merely refused,
        // rate limited say, gets read as a dead login, and the person is sent
        // round the whole consent flow again for nothing (L35, L93).
        //
        // So the code is read from the field that carries it. A body that is not
        // JSON, or carries no `error`, says nothing about the login and is
        // therefore transient: we do not know is not the same as it is dead, and
        // of the two ways to be wrong this is the recoverable one.
        if status == 401 { return .failure(.authExpired) }
        if status == 400,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = object["error"] as? String,
           code == "invalid_grant" {
            return .failure(.authExpired)
        }
        return .failure(.transient)
    }

    // MARK: - helpers

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formPost(to endpoint: String, fields: [String: String]) -> URLRequest {
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        return req
    }
}

// Decoded token response from Google.
public struct OAuthTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresIn: Int?

    // WHO GRANTED THIS, when Google says so (backstage#45).
    //
    // Present only when an identity scope was requested, so a consumer asking for
    // gmail.send alone gets nil here and that is correct rather than missing. It
    // is recorded so that "connected as X" can be true when it is knowable, and
    // honestly absent when it is not.
    public var idToken: String?

    // The email claim, read from the id token's payload.
    //
    // NOT VERIFIED, AND THAT IS SOUND HERE rather than an omission: this token
    // came back on our own TLS connection to Google's token endpoint in response
    // to our own request, which is the one case where a JWT needs no signature
    // check. It is never accepted from anywhere else, and it is used to LABEL a
    // grant, never to authorise anything.
    public var account: String? {
        guard let idToken else { return nil }
        let segments = idToken.split(separator: ".")
        guard segments.count == 3 else { return nil }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+")
                                         .replacingOccurrences(of: "_", with: "/")
        // Base64url drops the padding that Data(base64Encoded:) requires.
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["email"] as? String
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}
