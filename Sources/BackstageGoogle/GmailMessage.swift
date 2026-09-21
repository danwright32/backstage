// Ported-From: danwright32/overture mac/Overture/Integration/GmailMessage.swift @ 0bb3869c8f71777d08712e9fa146fd07c6da699f
// Ported-Adapted: 50b986034f80e8037a2992dc015f0e9b99988425ba0677e96cfd73743baa72b1
//
// ADAPTED AGAIN ON 2026-09-21 BY backstage#51, and the digest above was re-recorded
// deliberately rather than to quiet the guard. The rule in the paragraph below is
// "do not edit this copy to fix a FAULT that is also in the origin", and an
// attachment is not a fault: Overture sends pitches, nudges and closing notes, and
// none of them carries a file, so there is nothing at the origin to fix. Taking
// this to Overture would mean adding a capability that app does not want in order
// to re-port it here, which is the DIVERGED route paying a cost for nothing.
//
// WHAT DIVERGED, stated so the next reader does not have to diff two repositories:
// this copy can attach files and Overture's cannot. Everything else is unchanged,
// and the two message forms Overture actually produces (a single text/plain, and a
// multipart/alternative when the signature carries HTML) are byte for byte what
// they were, which `MailAttachmentTests` asserts through an outside parser.
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
                       references: String? = nil,
                       attachments: [MailAttachment] = [],
                       attachmentBoundary: String? = nil) -> String {
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
        let htmlPart = htmlPart(body: body, signature: signature)

        // backstage#51. THERE ARE FOUR MESSAGE FORMS, NOT TWO, and the fourth is
        // the one a change written as "become mixed when there is an attachment"
        // gets wrong. This was ALREADY multipart before attachments existed: an
        // HTML signature makes it `multipart/alternative` (#1144). So the two axes
        // are independent, and with both present the mixed part has to WRAP the
        // alternative rather than replace it. Replacing it drops the HTML part and
        // the loss is silent, because the mail still arrives, just plain.
        //
        //   no attachment, plain signature  ->  text/plain
        //   no attachment, HTML signature   ->  multipart/alternative
        //   attachment,    plain signature  ->  multipart/mixed [ text/plain, file ]
        //   attachment,    HTML signature   ->  multipart/mixed [ alternative, file ]
        //
        // The first two are byte for byte what they were, which is what keeps every
        // existing caller sending exactly the message it sent before.
        //
        // TWO BOUNDARIES, AND THEY MUST DIFFER. One value used for both means the
        // inner part's closing delimiter terminates the outer part as well, and the
        // attachment is simply not in the message a receiver parses. They are
        // separate arguments rather than one, so a test can pin both, and each
        // defaults to its own fresh UUID.
        func alternative(_ b: String) -> [String] {
            [
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
                htmlPart ?? "",
                "--\(b)--",
            ]
        }
        let plain = [
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            plainBody,
        ]

        if attachments.isEmpty {
            headers.append("MIME-Version: 1.0")
            headers += htmlPart != nil ? alternative(boundary ?? freshBoundary()) : plain
        } else {
            let mixed = attachmentBoundary ?? freshBoundary()
            headers += [
                "MIME-Version: 1.0",
                "Content-Type: multipart/mixed; boundary=\"\(mixed)\"",
                "",
                "--\(mixed)",
            ]
            headers += htmlPart != nil ? alternative(boundary ?? freshBoundary()) : plain
            for attachment in attachments {
                headers += ["--\(mixed)"] + attachmentPart(attachment)
            }
            headers.append("--\(mixed)--")
        }
        return headers.joined(separator: "\r\n")
    }

    // One attached file, base64 encoded.
    //
    // THE FILENAME PASSES THROUGH `headerSafe` LIKE EVERY OTHER HEADER VALUE,
    // which is backstage#4's rule and applies here for a reason rather than by
    // symmetry: Ovation builds this name from an invoice number and a client's
    // shoot, so it is as untrusted as a subject, and it is written into TWO
    // headers. It is also quoted, so the quote and the backslash are escaped:
    // `headerSafe` covers line breaks and a quoted string can be ended by a
    // character it says nothing about (L273).
    //
    // WRAPPED AT 76 CHARACTERS, which RFC 2045 requires. Gmail accepts an
    // unwrapped line, which is exactly why this is not left to chance: the fault
    // would appear at some receiving server and never in our own mailbox.
    private static func attachmentPart(_ attachment: MailAttachment) -> [String] {
        let name = quoted(headerSafe(attachment.filename))
        let type = headerSafe(attachment.mimeType)
        return [
            "Content-Type: \(type); name=\"\(name)\"",
            "Content-Transfer-Encoding: base64",
            "Content-Disposition: attachment; filename=\"\(name)\"",
            "",
            attachment.bytes.base64EncodedString(
                options: [.lineLength76Characters, .endLineWithCarriageReturn,
                          .endLineWithLineFeed]),
        ]
    }

    private static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
                         references: String? = nil,
                         attachments: [MailAttachment] = []) -> String {
        base64url(Data(rfc822(fromName: fromName, fromEmail: fromEmail, to: to, subject: subject, body: body,
                              signature: signature,
                              inReplyTo: inReplyTo,
                              references: references,
                              attachments: attachments).utf8))
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
