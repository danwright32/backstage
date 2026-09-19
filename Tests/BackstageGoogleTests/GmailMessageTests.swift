import Foundation
import Testing
@testable import BackstageGoogle

// The wire form Gmail expects: an RFC 2822 message, base64url encoded. backstage#2 step 2, and
// backstage#4.
struct GmailMessageTests {

    // The header block is everything before the first blank line, split on EVERY kind of line
    // break rather than only the CRLF the standard names. A lenient receiver honours a bare LF, a
    // bare CR or a Unicode separator as a line end, so the test has to read as the most lenient
    // receiver would. The first version split on CRLF alone, and its "every kind of line break"
    // case passed against the vulnerable code, because the reader could not see the very lines it
    // was looking for (L1).
    private func headers(_ message: String) -> [String] {
        var out: [String] = []
        for line in message.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.isEmpty { break }
            out.append(String(line))
        }
        return out
    }
    private func headerNames(_ message: String) -> [String] {
        headers(message).map { String($0.prefix { $0 != ":" }) }
    }

    private func plain(subject: String = "Invoice 1042", body: String = "Hello",
                       fromName: String = "Sender", fromEmail: String = "sender@example.com",
                       to: [String] = ["client@example.com"],
                       signature: MessageSignature = .none,
                       inReplyTo: String? = nil, references: String? = nil) -> String {
        GmailMessage.rfc822(fromName: fromName, fromEmail: fromEmail, to: to, subject: subject,
                            body: body, signature: signature, boundary: "B",
                            inReplyTo: inReplyTo, references: references)
    }

    @Test func aPlainMessageCarriesExactlyItsHeaders() {
        let m = plain()
        #expect(headerNames(m) == ["From", "To", "Subject", "MIME-Version", "Content-Type",
                                   "Content-Transfer-Encoding"])
        #expect(headers(m).contains("From: Sender <sender@example.com>"))
        #expect(m.hasSuffix("\r\n\r\nHello"))
    }

    @Test func severalRecipientsShareOneToLine() {
        #expect(headers(plain(to: ["a@example.com", "b@example.com"])).contains("To: a@example.com, b@example.com"))
    }

    @Test func aNonASCIISubjectIsEncodedSoHeadersStaySevenBit() {
        let m = plain(subject: "Café")
        #expect(headers(m).contains("Subject: =?UTF-8?B?\(Data("Café".utf8).base64EncodedString())?="))
    }

    @Test func aPlainSignOffIsAppendedOnce() {
        let m = plain(body: "Body", signature: MessageSignature(plainText: "Best,\nA Sender"))
        #expect(m.hasSuffix("Body\n\nBest,\nA Sender"))
    }

    @Test func anHTMLSignatureMakesTheMessageMultipart() {
        let m = plain(body: "Line one\n<b>not bold</b>",
                      signature: MessageSignature(plainText: "Best", html: "<p>Best</p>"))
        #expect(headers(m).contains("Content-Type: multipart/alternative; boundary=\"B\""))
        #expect(m.contains("Content-Type: text/plain; charset=UTF-8"))
        #expect(m.contains("Content-Type: text/html; charset=UTF-8"))
        // The drafted body is escaped in the HTML part so it cannot inject markup, and its line
        // breaks survive. The signature is HTML already and goes in as given.
        #expect(m.contains("&lt;b&gt;not bold&lt;/b&gt;"))
        #expect(m.contains("Line one<br>"))
        #expect(m.contains("<p>Best</p>"))
        #expect(m.hasSuffix("--B--"))
    }

    // THE PACKAGE CARRIES NO CONSUMER'S CONTENT. The origin rewrote one app's website address into
    // a link inside every body, and stamped its own name into the boundary.
    @Test func noAppsOwnRulesRideInTheMessage() {
        let m = GmailMessage.rfc822(fromName: "S", fromEmail: "s@example.com", to: ["c@example.com"],
                                    subject: "S", body: "see https://example.com/work",
                                    signature: MessageSignature(plainText: "x", html: "<p>x</p>"),
                                    boundary: nil)
        #expect(!m.contains("<a href"))
        #expect(!m.lowercased().contains("overture"))
    }

    @Test func aReplyThreadsOntoItsParent() {
        let m = plain(inReplyTo: "<p@example.com>", references: "<a@example.com> <p@example.com>")
        #expect(headers(m).contains("In-Reply-To: <p@example.com>"))
        #expect(headers(m).contains("References: <a@example.com> <p@example.com>"))
    }

    @Test func referencesFallBackToTheParentAlone() {
        #expect(headers(plain(inReplyTo: "<p@example.com>")).contains("References: <p@example.com>"))
    }

    @Test func theRawFieldIsTheMessageBase64urlEncoded() throws {
        let raw = GmailMessage.rawField(fromName: "S", fromEmail: "s@example.com", to: ["c@example.com"],
                                        subject: "Hi", body: "Body")
        #expect(!raw.contains("+") && !raw.contains("/") && !raw.contains("="))
        var b64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let decoded = String(data: try #require(Data(base64Encoded: b64)), encoding: .utf8) ?? ""
        #expect(decoded.contains("Subject: Hi"))
    }

    // ---------- backstage#4: no value can add a header ----------
    //
    // A plain ASCII subject carrying a line break used to become an ADDITIONAL header, for
    // instance a second recipient, because every value was interpolated straight in. Each field
    // that reaches a header is tried here, since a fix applied to the subject alone would leave the
    // other five open (L30). What is asserted is the whole header set, not the absence of one
    // string, because a check that a rewrite does not contain something is satisfied by one that
    // deleted it (L283).
    private static let injection = "\r\nBcc: attacker@example.org"
    private static let expected = ["From", "To", "Subject", "MIME-Version", "Content-Type",
                                   "Content-Transfer-Encoding"]

    @Test func aLineBreakInTheSubjectCannotAddAHeader() {
        let m = plain(subject: "Invoice" + Self.injection)
        #expect(headerNames(m) == Self.expected)
        // The text is kept, on its own header's line, rather than silently dropped.
        #expect(headers(m).contains { $0.hasPrefix("Subject: Invoice") && $0.contains("Bcc: attacker@example.org") })
    }

    @Test func aLineBreakInTheSenderNameCannotAddAHeader() {
        #expect(headerNames(plain(fromName: "Name" + Self.injection)) == Self.expected)
    }

    @Test func aLineBreakInTheSenderAddressCannotAddAHeader() {
        #expect(headerNames(plain(fromEmail: "s@example.com" + Self.injection)) == Self.expected)
    }

    @Test func aLineBreakInARecipientCannotAddAHeader() {
        #expect(headerNames(plain(to: ["c@example.com" + Self.injection])) == Self.expected)
    }

    @Test func aLineBreakInTheThreadingFieldsCannotAddAHeader() {
        let m = plain(inReplyTo: "<p@x>" + Self.injection, references: "<a@x>" + Self.injection)
        #expect(headerNames(m) == ["From", "To", "Subject", "In-Reply-To", "References",
                                   "MIME-Version", "Content-Type", "Content-Transfer-Encoding"])
    }

    // Every kind of line break a parser might honour, not only the CR LF the incident used: a bare
    // CR, a bare LF, and the Unicode separators (L273: a normalization covers only the classes its
    // author thought of, so name them all).
    @Test func noKindOfLineBreakCanAddAHeader() {
        for brk in ["\n", "\r", "\u{2028}", "\u{2029}", "\u{0085}", "\u{000B}", "\u{000C}"] {
            let m = plain(subject: "A\(brk)Bcc: attacker@example.org")
            #expect(headerNames(m) == Self.expected, "line break \(brk.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    // The body is NOT a header and keeps its line breaks.
    @Test func theBodyKeepsItsLineBreaks() {
        #expect(plain(body: "one\ntwo").hasSuffix("one\ntwo"))
    }
}
