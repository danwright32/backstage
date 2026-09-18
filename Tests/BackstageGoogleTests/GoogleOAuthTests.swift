import Foundation
import Testing
@testable import BackstageGoogle

// The OAuth primitives, ported from Overture. backstage#2.
//
// THESE ARE NOT NEW BEHAVIOUR, so the tests exist to prove the move did not
// break anything, and they are written against the port source's own documented
// contract rather than against whatever the moved code happens to do.
struct GoogleOAuthTests {

    // PKCE: a random verifier and its SHA-256 challenge, both base64url with no
    // padding. Fixed bytes rather than random ones, because a test whose input
    // comes from system entropy differs on every run and can assert nothing
    // about the value (L339).
    // THE EXPECTED VALUES WERE DERIVED INDEPENDENTLY, in Python, from the RFC
    // 7636 definition (challenge = base64url(SHA256(ascii(verifier)))), and not
    // read off what this code produced. A test whose expectation comes from the
    // implementation can only confirm the implementation is self consistent,
    // never that it is correct (L70). The first version of this test carried a
    // hash nobody had computed, and it failed against correct code.
    @Test func makesABase64urlVerifierAndItsChallenge() {
        let bytes = Data((0..<32).map { UInt8($0) })
        let pkce = GoogleOAuth.makePKCE(verifierBytes: bytes)

        #expect(pkce.verifier == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        #expect(pkce.challenge == "6oZqdX5MOLq_qBJ8vppAnT4fk6AP8UiP9zX8-Rev_9A")
    }

    // base64url is base64 with two characters swapped and the padding removed,
    // so a value containing either of them is the only one that can tell the
    // two apart. These bytes produce both a plus and a slash in plain base64.
    @Test func base64urlNeverEmitsPlusSlashOrPadding() {
        let bytes = Data([0xFB, 0xFF, 0xFE])
        let pkce = GoogleOAuth.makePKCE(verifierBytes: bytes)

        #expect(pkce.verifier == "-__-")
        #expect(!pkce.verifier.contains("+"))
        #expect(!pkce.verifier.contains("/"))
        #expect(!pkce.verifier.contains("="))
    }

    // THE SCOPES A CONSUMER NAMED ARE THE SCOPES THAT GO, and nothing adds to
    // them. backstage#3 is the whole rule; this is the half of it that lives
    // here, where the authorization URL is built.
    @Test func carriesExactlyTheScopesTheConsumerNamed() throws {
        let config = OAuthConfig(clientId: "cid", clientSecret: "secret",
                                 redirectURI: "http://127.0.0.1:9999",
                                 scopes: ["https://www.googleapis.com/auth/gmail.send"])
        let url = GoogleOAuth.authorizationURL(config: config, pkce: PKCE(verifier: "v", challenge: "c"), state: "st")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(value("scope") == "https://www.googleapis.com/auth/gmail.send")
        #expect(value("client_id") == "cid")
        #expect(value("code_challenge") == "c")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("state") == "st")
    }
}
