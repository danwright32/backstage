// Ported-From: danwright32/overture mac/Overture/Integration/GmailMessage.swift @ 0bb3869c8f71777d08712e9fa146fd07c6da699f
// Ported-Adapted: f276779ee5eaab458d03262ae41b146328a5582a3f2bf2552c8972444c0c34de
//
// Ported on 2026-09-19 by backstage#2 (step 2). Do not edit this copy to fix a fault that is also
// in the origin: fix it there and re-port (L263).
//
// DELIBERATE CHANGES, each for the principle that the package carries no consumer's content:
// the three preview helpers are gone (Dan, 2026-09-18: Ovation renders its own review surfaces);
// the signature is MessageSignature, rendered by the consumer, not the origin's own type; the
// origin's rewriting of its own website address into a link inside every body is gone, so an app
// that wants that does it before calling here; the boundary no longer names the origin; and the
// origin's threading repair recogniser, which only that repair calls, stayed behind.
import Foundation

// Builds the wire form the Gmail API expects: an RFC 2822 message, base64url-encoded,
// posted as {"raw": ...} to users/me/messages/send. Pure and testable; the network
// call and OAuth token live in GmailSender (the next slice).

enum GmailMessage {
    // base64url with no padding, as the Gmail API requires for the `raw` field.
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // The plain text body with the sign-off appended, exactly as the text/plain part carries it.
    // One definition, used by both parts, so the two can never disagree about the sign-off.
    private static func plainBody(body: String, signature: MessageSignature) -> String {
        signature.plainText.isEmpty ? body : body + "\n\n" + signature.plainText
    }

    // The text/html part, or nil when the signature carries no HTML and the message stays plain.
    private static func htmlPart(body: String, signature: MessageSignature) -> String? {
        guard let html = signature.html, !html.isEmpty else { return nil }
        return htmlDocument(body: body, signatureHTML: html)
    }

    // copy-inventory:ignore-start  RFC822 headers: a mail server reads these, not Dan (#915)

    // An RFC 2822 message. From is the authorized sender; the subject is RFC 2047 encoded only when it
    // contains non-ASCII (e.g. an accented org name) so headers stay 7-bit clean. #1144: when the
    // signature carries HTML the message is multipart/alternative (a text/plain part plus a text/html part
    // that renders the styled Gmail signature); otherwise it stays a single text/plain part. The sign-off
    // is appended HERE, once, so no body producer carries its own.
    static func rfc822(fromName: String, fromEmail: String, to: [String], subject: String, body: String,
                       signature: MessageSignature = .none, boundary: String? = nil,
                       inReplyTo: String? = nil,
                       references: String? = nil) -> String {
        // backstage#4, PRD 5.10b. EVERY value that reaches a header passes through headerSafe first.
        // The origin interpolated them straight in, so a plain ASCII subject carrying a line break
        // became an ADDITIONAL header, a second recipient say. Harmless while nothing untrusted
        // reached a subject; not here, where a subject carries a client name and a shoot name.
        let subject = headerSafe(subject)
        let fromName = headerSafe(fromName)
        let fromEmail = headerSafe(fromEmail)
        let to = to.map(headerSafe)
        let inReplyTo = inReplyTo.map(headerSafe)
        let references = references.map(headerSafe)
        let headerSubject = isASCII(subject) ? subject : encodedWord(subject)
        var headers = [
            "From: \(fromName) <\(fromEmail)>",
            // #2030: several people ride ONE `To:` line, comma separated, which is what RFC 2822 means by
            // an address list. Joined here, beside the header, so there is one definition of it.
            "To: \(to.joined(separator: ", "))",
            "Subject: \(headerSubject)",
        ]
        // #74: thread a follow-up onto the original, by pointing In-Reply-To/References at the id of the
        // message being replied to, which is what makes mail clients (and Gmail's reply detection) treat
        // the reply as part of the same conversation.
        //
        // #2672: no `Message-ID:` header is written here any more. Gmail discards a client-supplied one
        // and stamps its own (#2647), so this header could only ever be a value nothing on the wire
        // carried, and every id Overture stores is now read BACK off the send.
        if let inReplyTo { headers.append("In-Reply-To: \(inReplyTo)") }
        // #2648: References is the WHOLE ancestry, oldest first, not the parent restated. It used to be
        // written as the single `inReplyTo` value, so a third message on a conversation named only the
        // second and a client walking the chain had no link back to the first.
        //
        // Falling back to `inReplyTo` when no chain is supplied keeps the old behaviour as the floor: the
        // parent's id alone is an incomplete References but a valid one, and it is strictly better than
        // dropping the header for a caller that has not been taught the chain yet.
        if let refs = references ?? inReplyTo, !refs.isEmpty {
            headers.append("References: \(refs)")
        }
        let plainBody = plainBody(body: body, signature: signature)
        if let htmlPart = htmlPart(body: body, signature: signature) {
            let b = boundary ?? freshBoundary()
            headers += [
                "MIME-Version: 1.0",
                "Content-Type: multipart/alternative; boundary=\"\(b)\"",
                "",
                "--\(b)",
                "Content-Type: text/plain; charset=UTF-8",
                "Content-Transfer-Encoding: 8bit",
                "",
                plainBody,
                "--\(b)",
                "Content-Type: text/html; charset=UTF-8",
                "Content-Transfer-Encoding: 8bit",
                "",
                htmlPart,
                "--\(b)--",
            ]
        } else {
            headers += [
                "MIME-Version: 1.0",
                "Content-Type: text/plain; charset=UTF-8",
                "Content-Transfer-Encoding: 8bit",
                "",
                plainBody,
            ]
        }
        return headers.joined(separator: "\r\n")
    }

    // The text/html part: the drafted body, HTML-escaped and newline-to-<br> so it can't inject markup and
    // its line breaks survive, followed by the styled signature (already HTML, inserted verbatim).
    private static func htmlDocument(body: String, signatureHTML: String) -> String {
        let escaped = htmlEscape(body).replacingOccurrences(of: "\n", with: "<br>\n")
        return "<div>\(escaped)</div><br>\n\(signatureHTML)"
    }

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")   // must be first
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // A unique MIME boundary. Not derived from the content, so it can never appear inside either part.
    private static func freshBoundary() -> String { "=_Backstage_\(UUID().uuidString)" }
    // copy-inventory:ignore-end

    static func rawField(fromName: String, fromEmail: String, to: [String], subject: String, body: String,
                         signature: MessageSignature = .none,
                         inReplyTo: String? = nil,
                         references: String? = nil) -> String {
        base64url(Data(rfc822(fromName: fromName, fromEmail: fromEmail, to: to, subject: subject, body: body,
                              signature: signature,
                              inReplyTo: inReplyTo,
                              references: references).utf8))
    }

    // #2672: `newMessageID` is GONE. It minted an id for the send path to stamp, and #2647 stopped that
    // path stamping anything, leaving a generator with no caller outside its own test. It comes back only
    // if a genuine NON-Gmail sender ever appears, which is the only kind of caller for which a
    // self-minted id is a fact rather than a request (L127).

    private static func isASCII(_ s: String) -> Bool { s.allSatisfy { $0.isASCII } }

    // A header value with every line break replaced by a space, so it stays on its own header's line
    // and cannot start another. EVERY kind of break, not only the CR LF the standard names: a lenient
    // receiver honours a bare LF, a bare CR, a vertical tab, a form feed or a Unicode separator as a
    // line end too, and a normalization written for one class covers only that class (L273).
    // Replaced rather than removed, so "Invoice<LF>Bcc: x" reads as "Invoice Bcc: x" rather than
    // fusing two words, and nothing the person wrote silently disappears.
    static func headerSafe(_ value: String) -> String {
        String(value.map { $0.isNewline ? " " : $0 })
    }

    // RFC 2047 encoded-word: =?UTF-8?B?<base64>?=
    private static func encodedWord(_ s: String) -> String {
        "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }
}

// The sign-off a message carries: plain text for the text/plain part, and optionally HTML for a
// text/html part. RENDERED by the consumer, who owns what it says and how it looks; the package only
// appends it. That is the decision recorded on backstage#2 (Dan, 2026-09-18): a package three apps
// consume must not carry any one of them's sign-off.
public struct MessageSignature: Equatable, Sendable {
    public var plainText: String
    // Already sendable HTML. Anything the consumer needs to strip or restyle is done before it gets
    // here, because the package has no view of what that app's signatures contain.
    public var html: String?

    public init(plainText: String, html: String? = nil) {
        self.plainText = plainText
        self.html = html
    }

    // No sign-off at all, so a caller that passes nothing sends exactly the body.
    public static let none = MessageSignature(plainText: "")
}
