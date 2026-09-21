import Foundation
import Testing
@testable import BackstageGoogle

/// backstage#51. An outgoing mail carrying a file, and the four message forms that
/// fall out of it.
///
/// WHY FOUR AND NOT TWO. `rfc822` was already multipart before this: it builds a
/// `multipart/alternative` whenever the signature carries HTML, and a single
/// `text/plain` otherwise. So an attachment is not "make it multipart", it is a
/// second axis, and the cell that breaks a change written as "become mixed when
/// there is an attachment" is the one with BOTH: a `multipart/mixed` has to wrap
/// the `multipart/alternative` rather than replace it, or the HTML part is
/// silently dropped.
///
/// THE MESSAGE IS PARSED BY SOMETHING THAT DID NOT BUILD IT. Every case below
/// hands the produced message to Python's `email` package and asserts on the tree
/// it reports. Asserting that the string contains the boundary and the filename
/// this very file just wrote into it can only confirm our own assumption about
/// MIME, which is the thing under test (L52).
struct MailAttachmentTests {

    // MARK: parsing the message with something else

    /// One part of a parsed message, as Python's `email` package sees it.
    struct ParsedPart: Equatable, CustomStringConvertible {
        let contentType: String
        let filename: String?
        /// The decoded payload's length in bytes, for a leaf part.
        let decodedBytes: Int?
        let children: [ParsedPart]

        var description: String { render(indent: 0) }

        private func render(indent: Int) -> String {
            let pad = String(repeating: "  ", count: indent)
            var line = pad + contentType
            if let filename { line += " name=\(filename)" }
            if let decodedBytes { line += " bytes=\(decodedBytes)" }
            return ([line] + children.map { $0.render(indent: indent + 1) }).joined(separator: "\n")
        }
    }

    /// Runs the message through Python's `email` package and reads back the tree.
    ///
    /// AN INDEPENDENT READER, and that is the whole point of shelling out. The
    /// alternative is a MIME parser written in this file by the same hand that
    /// wrote the builder, which agrees with the builder by construction and would
    /// go on agreeing with it while both were wrong.
    static func parse(_ message: String) throws -> ParsedPart {
        let script = """
        import email, email.policy, json, sys
        m = email.message_from_string(sys.stdin.read(), policy=email.policy.default)
        def walk(p):
            node = {"type": p.get_content_type(), "name": p.get_filename(), "children": []}
            if p.is_multipart():
                node["children"] = [walk(c) for c in p.iter_parts()]
            else:
                node["bytes"] = len(p.get_content().encode() if isinstance(p.get_content(), str)
                                    else p.get_content())
            return node
        json.dump(walk(m), sys.stdout)
        """
        let out = try runPython(script, stdin: message)
        let node = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        return try #require(node.map(Self.part(from:)), "the parser returned nothing")
    }

    private static func part(from node: [String: Any]) -> ParsedPart {
        ParsedPart(
            contentType: node["type"] as? String ?? "?",
            filename: node["name"] as? String,
            decodedBytes: node["bytes"] as? Int,
            children: (node["children"] as? [[String: Any]] ?? []).map(Self.part(from:)))
    }

    private static func runPython(_ script: String, stdin: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        input.fileHandleForWriting.closeFile()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let problem = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // A PARSER THAT DID NOT RUN IS NOT A PASS (L98). Without this, a missing
        // python3 would hand every case below an empty tree and they would all
        // fail on the wrong thing, or worse be written to tolerate it.
        guard process.terminationStatus == 0 else {
            throw Failure.parserRefused(String(data: problem, encoding: .utf8) ?? "")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    enum Failure: Error { case parserRefused(String) }

    // MARK: the fixtures

    private static let pdf = Data("%PDF-1.4 pretend this is an invoice".utf8)

    private static func attachment() -> MailAttachment {
        MailAttachment(filename: "invoice-1123.pdf", mimeType: "application/pdf", bytes: pdf)!
    }

    private static func message(
        signature: MessageSignature = .none,
        attachments: [MailAttachment] = []
    ) -> String {
        GmailMessage.rfc822(fromName: "Dan Wright", fromEmail: "dan@example.com",
                            to: ["client@example.com"], subject: "Invoice 1123",
                            body: "Invoice 1123 is attached.",
                            signature: signature, attachments: attachments)
    }

    private static let htmlSignature = MessageSignature(plainText: "Dan Wright",
                                                        html: "<b>Dan Wright</b>")

    // MARK: the four cells

    @Test("no attachment and no HTML signature is still one plain part")
    func plainWithNothingAttached() throws {
        let tree = try Self.parse(Self.message())

        #expect(tree.contentType == "text/plain")
        #expect(tree.children.isEmpty)
    }

    @Test("an HTML signature and no attachment is still multipart/alternative")
    func htmlSignatureWithNothingAttached() throws {
        let tree = try Self.parse(Self.message(signature: Self.htmlSignature))

        #expect(tree.contentType == "multipart/alternative")
        #expect(tree.children.map(\.contentType) == ["text/plain", "text/html"])
    }

    @Test("an attachment with no HTML signature is mixed, text then the file")
    func attachmentWithPlainSignature() throws {
        let tree = try Self.parse(Self.message(attachments: [Self.attachment()]))

        #expect(tree.contentType == "multipart/mixed")
        #expect(tree.children.map(\.contentType) == ["text/plain", "application/pdf"])
        #expect(tree.children.last?.filename == "invoice-1123.pdf")
        #expect(tree.children.last?.decodedBytes == Self.pdf.count,
                "the bytes that came back out are not the bytes that went in")
    }

    /// THE CELL A CHANGE WRITTEN AS "BECOME MIXED" GETS WRONG. The alternative has
    /// to survive INSIDE the mixed part. Replacing it loses the HTML signature,
    /// and the loss is silent: the mail arrives, it is just plain.
    @Test("an attachment AND an HTML signature nests alternative inside mixed")
    func attachmentWithHTMLSignature() throws {
        let tree = try Self.parse(
            Self.message(signature: Self.htmlSignature, attachments: [Self.attachment()]))

        #expect(tree.contentType == "multipart/mixed")
        #expect(tree.children.map(\.contentType) == ["multipart/alternative", "application/pdf"])
        #expect(tree.children.first?.children.map(\.contentType) == ["text/plain", "text/html"])
        #expect(tree.children.last?.decodedBytes == Self.pdf.count)
    }

    @Test("the two boundaries differ, so the inner part cannot close the outer one")
    func theboundariesDiffer() throws {
        let raw = Self.message(signature: Self.htmlSignature, attachments: [Self.attachment()])
        let boundaries = raw.split(separator: "\r\n")
            .filter { $0.contains("boundary=") }
            .map(String.init)

        #expect(boundaries.count == 2, "expected an outer and an inner boundary")
        #expect(boundaries.first != boundaries.last,
                "one boundary for both parts lets the inner part terminate the outer one")
    }

    @Test("several attachments all arrive")
    func severalAttachments() throws {
        let second = MailAttachment(filename: "receipt.pdf", mimeType: "application/pdf",
                                    bytes: Data("%PDF-1.4 another".utf8))!
        let tree = try Self.parse(Self.message(attachments: [Self.attachment(), second]))

        #expect(tree.children.compactMap(\.filename) == ["invoice-1123.pdf", "receipt.pdf"])
    }

    // MARK: the encoding

    /// RFC 2045 caps an encoded line at 76 characters. Gmail accepts an unwrapped
    /// one, which is exactly why this is asserted here: the fault would appear at
    /// some receiving server months later and never in our own mailbox.
    @Test("the base64 is wrapped, so no encoded line runs past what RFC 2045 allows")
    func thebase64IsWrapped() {
        let big = MailAttachment(filename: "big.pdf", mimeType: "application/pdf",
                                 bytes: Data(repeating: 0x41, count: 5_000))!
        let raw = Self.message(attachments: [big])

        // THE ENCODED LINES, NOT EVERY LINE, and the difference is why the first
        // version of this case failed on correct output. RFC 2045's 76 applies to
        // the encoded content; a header may legitimately be longer, and
        // `Content-Type: multipart/mixed; boundary="=_Backstage_<uuid>"` is about
        // 88 characters on its own.
        let base64Lines = raw.split(separator: "\r\n")
            .filter { line in
                !line.isEmpty && line.allSatisfy {
                    $0.isLetter && $0.isASCII || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "="
                }
            }

        // THE POSITIVE CONTROL. 5,000 bytes encode to about 6,668 characters, so
        // an unwrapped blob is ONE line and the filter below would have nothing
        // long to find. Asserting the count first means the case cannot pass by
        // measuring the wrong thing (L159).
        #expect(base64Lines.count > 80,
                "\(base64Lines.count) encoded line(s), so nothing was wrapped")
        let longest = base64Lines.map(\.count).max() ?? 0
        #expect(longest <= 76, "an encoded line of \(longest) characters")
    }

    // MARK: the size Gmail will take

    /// REFUSED ON THE ENCODED REQUEST, NEVER ON THE FILE'S OWN SIZE, and the two
    /// fixtures below are what makes that a measurement rather than a claim. A
    /// file grows roughly 1.8x between here and the request: base64 into its part,
    /// then the whole message base64url encoded into `raw`.
    ///
    /// BOTH FIXTURES ARE DERIVED FROM THE LIMIT, never written as literals at its
    /// edge, so the day the constant moves they still mean what they say (L401).
    @Test("a message too large for Gmail is refused before it is sent, by name")
    func toolargeIsRefused() async throws {
        // Comfortably over once encoded, and comfortably under as a raw file, so
        // a refusal written against the attachment's own byte count would let it
        // through. That is the whole case.
        let bytes = GmailSender.maximumRawRequestBytes * 3 / 4
        let big = MailAttachment(filename: "big.pdf", mimeType: "application/pdf",
                                 bytes: Data(repeating: 0x41, count: bytes))!
        let mail = OutgoingMail(to: ["client@example.com"], subject: "Invoice 1123",
                                body: "attached", attachments: [big])!

        var reached = false
        await #expect(throws: GmailSendError.self) {
            _ = try await GmailSender.performSend(
                mail: mail, fromName: "Dan", fromEmail: "dan@example.com", token: "tok",
                fetch: { _ in reached = true; throw Self.Failure.parserRefused("not reached") },
                onAuthExpired: {})
        }
        #expect(bytes < GmailSender.maximumRawRequestBytes,
                "the fixture is already over the limit as a plain file, so this case cannot tell the two units apart")
        #expect(!reached, "the request was sent anyway, which is what the refusal exists to stop")
    }

    /// THE POSITIVE CONTROL. Without it a sender that refused everything would pass
    /// the case above (L159).
    @Test("and one that fits is sent")
    func onethatFitsIsSent() async throws {
        let small = MailAttachment(filename: "small.pdf", mimeType: "application/pdf",
                                   bytes: Self.pdf)!
        let mail = OutgoingMail(to: ["client@example.com"], subject: "Invoice 1123",
                                body: "attached", attachments: [small])!

        var reached = false
        _ = try? await GmailSender.performSend(
            mail: mail, fromName: "Dan", fromEmail: "dan@example.com", token: "tok",
            fetch: { _ in
                reached = true
                throw Self.Failure.parserRefused("stop here, the point is that we got this far")
            },
            onAuthExpired: {})

        #expect(reached, "a message well under the limit never reached the request")
    }

    // MARK: what cannot be built

    @Test("an attachment with no filename, no type or no bytes cannot be made",
          arguments: [("", "application/pdf", 3), ("a.pdf", "", 3), ("a.pdf", "application/pdf", 0)])
    func anincompleteAttachmentIsRefused(filename: String, mimeType: String, byteCount: Int) {
        // A PLACEHOLDER FOR A MISSING REQUIRED VALUE IS A DETECTION, not a label
        // (L67). A part with an empty filename arrives as something the client
        // cannot save, and an empty one arrives as a file that is not there.
        #expect(MailAttachment(filename: filename, mimeType: mimeType,
                               bytes: Data(repeating: 0x41, count: byteCount)) == nil)
    }

    /// EVERY VALUE THAT REACHES A HEADER PASSES THROUGH `headerSafe`, which is
    /// backstage#4's rule, and a filename is one: it is written into both
    /// `Content-Type` and `Content-Disposition`. A filename carrying a line break
    /// would otherwise add a header of its own, and this one is supplied from an
    /// invoice number and a client's shoot.
    @Test("a line break in a filename cannot add a header")
    func alineBreakInAFilenameCannotAddAHeader() throws {
        let sneaky = MailAttachment(filename: "a.pdf\r\nBcc: someone@example.com",
                                    mimeType: "application/pdf", bytes: Self.pdf)!
        let raw = Self.message(attachments: [sneaky])

        // ASKED OF THE PARSER, NOT OF THE TEXT. The first version asserted the
        // message does not CONTAIN "Bcc:", which is a different and wrong claim:
        // `headerSafe` turns the break into a space, so those characters are still
        // in the message, harmlessly inside a quoted filename. What matters is
        // whether a receiver reads a header there, and only a parser can say.
        let headers = try Self.headerNames(of: raw)

        #expect(!headers.contains("bcc"), "a filename became a header")
        #expect(headers.contains("subject"),
                "no headers were read at all, so this case proves nothing")
    }

    /// Every header name the parser reads at the top level, lowercased.
    static func headerNames(of message: String) throws -> [String] {
        let script = """
        import email, email.policy, json, sys
        m = email.message_from_string(sys.stdin.read(), policy=email.policy.default)
        json.dump([k.lower() for k in m.keys()], sys.stdout)
        """
        let out = try runPython(script, stdin: message)
        return try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String] ?? []
    }
}
