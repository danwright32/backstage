// Ported-From: danwright32/overture mac/Overture/Integration/GoogleOAuth.swift @ 750464734bffc8bd0af69898b13ec3e42d233c02
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
// 2. The consumer facing types and functions are `public`. The origin is one app,
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
        let body = String(data: data, encoding: .utf8) ?? ""
        if status == 401 || (status == 400 && body.contains("invalid_grant")) {
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

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
