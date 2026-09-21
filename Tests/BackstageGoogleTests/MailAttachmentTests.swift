import Foundation
import Testing
@testable import BackstageGoogle

// An attachment on an outgoing mail: backstage#51.
//
// EVERY ASSERTION HERE READS A DECODED MESSAGE, never the string the producer just wrote. The
// decoder is MIMEReader, calibrated in MIMEReaderTests against a message written by hand (L52).
struct MailAttachmentTests {

    // Bytes that are not text, with a NUL in them, so anything that took this through a String
    // loses them and says so rather than passing.
    private let pdfBytes = Data([0x25, 0x50, 0x44, 0x46] + (0...255).map(UInt8.init) + [0x00, 0xFF])
    private var invoice: MailAttachment {
        MailAttachment(filename: "Invoice 1042.pdf", mimeType: "application/pdf", data: pdfBytes)!
    }

    private func message(signature: MessageSignature = .none,
                         attachments: [MailAttachment] = [],
                         body: String = "Attached.") throws -> MIMEReader.Part {
        try MIMEReader.parse(GmailMessage.rfc822(
            fromName: "Sender", fromEmail: "sender@example.com", to: ["client@example.com"],
            subject: "Invoice 1042", body: body, signature: signature, attachments: attachments,
            boundary: "MIXED", alternativeBoundary: "ALT"))
    }

    private let html = MessageSignature(plainText: "Best", html: "<p>Best</p>")

    // ---------------------------------------------------------------------------------------
    // THE FOUR CELLS. The signature decides whether there is an HTML part and the mail decides
    // whether there is an attachment, so the shape is chosen from two sources and there are four
    // answers, not two. A change written as "become mixed when there is an attachment" gets the
    // fourth one wrong by dropping the HTML part, and only a test per cell can see it.

    @Test func plainAndUnattachedIsOneTextPart() throws {
        let m = try message()
        #expect(m.contentType == "text/plain")
        #expect(m.parts.isEmpty)
        #expect(m.text == "Attached.")
    }

    @Test func htmlAndUnattachedIsAnAlternativeOfTwo() throws {
        let m = try message(signature: html)
        #expect(m.contentType == "multipart/alternative")
        #expect(m.parts.map(\.contentType) == ["text/plain", "text/html"])
        #expect(m.parts[1].text.contains("<p>Best</p>"))
    }

    @Test func plainAndAttachedIsAMixedOfTheTextAndTheFile() throws {
        let m = try message(attachments: [invoice])
        #expect(m.contentType == "multipart/mixed")
        #expect(m.parts.map(\.contentType) == ["text/plain", "application/pdf"])
        #expect(m.parts[0].text == "Attached.")
        #expect(m.parts[1].body == pdfBytes)
    }

    // THE CELL A CHANGE WRITTEN THE OBVIOUS WAY GETS WRONG: both text parts have to survive, inside
    // an alternative of their own, inside the mixed.
    @Test func htmlAndAttachedKeepsBothTextPartsInsideTheMixed() throws {
        let m = try message(signature: html, attachments: [invoice])
        #expect(m.contentType == "multipart/mixed")
        #expect(m.parts.map(\.contentType) == ["multipart/alternative", "application/pdf"])
        #expect(m.parts[0].parts.map(\.contentType) == ["text/plain", "text/html"])
        #expect(m.parts[0].parts[0].text.hasPrefix("Attached."))
        #expect(m.parts[0].parts[1].text.contains("<p>Best</p>"))
        #expect(m.parts[1].body == pdfBytes)
    }

    // THE TWO BOUNDARIES ARE DIFFERENT, or the inner alternative's closing delimiter ends the outer
    // mixed and every part after it disappears.
    // ONLY THE MIXED BOUNDARY IS GIVEN, deliberately: the nested alternative has to mint its own.
    // Given both, or given neither, a version that reuses one boundary for both still produces two
    // different strings and this passes while the defect ships.
    @Test func theNestedAlternativeGetsItsOwnBoundary() throws {
        let raw = GmailMessage.rfc822(fromName: "S", fromEmail: "s@example.com", to: ["c@example.com"],
                                      subject: "S", body: "b", signature: html, attachments: [invoice],
                                      boundary: "MIXED")
        let m = try MIMEReader.parse(raw)
        let outer = try #require(m.parameters["boundary"])
        let inner = try #require(m.parts[0].parameters["boundary"])
        #expect(outer != inner)
    }

    // ---------------------------------------------------------------------------------------
    // WHAT THE FILE ITSELF CARRIES

    @Test func theFilenameAndTypeArriveWithTheBytes() throws {
        let part = try message(attachments: [invoice]).parts[1]
        #expect(part.contentType == "application/pdf")
        #expect(part.dispositionFilename == "Invoice 1042.pdf")
        #expect(part.disposition == "attachment")
        #expect(part.body == pdfBytes)
    }

    @Test func severalAttachmentsAllArriveInOrder() throws {
        let second = MailAttachment(filename: "notes.txt", mimeType: "text/plain", data: Data("hello".utf8))!
        let m = try message(attachments: [invoice, second])
        #expect(m.parts.map(\.contentType) == ["text/plain", "application/pdf", "text/plain"])
        #expect(m.parts[1].dispositionFilename == "Invoice 1042.pdf")
        #expect(m.parts[2].dispositionFilename == "notes.txt")
        #expect(m.parts[2].text == "hello")
    }

    // TWO DIFFERENT LIMITS, and the first version of this test confused them: it applied 76 to every
    // line and went red on a perfectly legal boundary header. RFC 2045 caps an ENCODED BODY line at
    // 76; RFC 5322 caps ANY line at 998. So there is one test each.

    // A body written as one enormous line is rejected or silently rewrapped on the way, and a rewrap
    // corrupts what it rewraps.
    @Test func noEncodedBodyLineRunsPastSeventySix() throws {
        let lines = GmailMessage.rfc822(
            fromName: "S", fromEmail: "s@example.com", to: ["c@example.com"], subject: "S",
            body: "b", attachments: [invoice], boundary: "MIXED")
            .components(separatedBy: "\r\n")
        let start = try #require(lines.firstIndex(of: "Content-Transfer-Encoding: base64")) + 2
        let end = try #require(lines[start...].firstIndex { $0.hasPrefix("--MIXED") })
        let encoded = lines[start..<end]
        #expect(!encoded.isEmpty)
        #expect(encoded.allSatisfy { $0.count <= 76 })
    }

    @Test func noLineAtAllRunsPastTheHardLimit() throws {
        let raw = GmailMessage.rfc822(fromName: "S", fromEmail: "s@example.com", to: ["c@example.com"],
                                      subject: "S", body: "b", attachments: [invoice])
        let overLong = raw.components(separatedBy: "\r\n").filter { $0.count > GmailMessage.maxHeaderLineLength }
        #expect(overLong.map(\.count) == [])
    }

    // AND THE ONLY WAY A CALLER COULD BREACH THAT LIMIT IS REFUSED AT CONSTRUCTION. Everything else
    // in the message is bounded by the package; a filename is not, and it reaches two headers, so a
    // long enough one produces a malformed message that Gmail answers with an opaque 400. Measured
    // in the unit the limit is expressed in, the RENDERED header line, not the character count of
    // the name: percent encoding makes one non-ASCII character up to twelve characters (L81).
    @Test func aFilenameTooLongForItsHeaderLineIsRefused() {
        let tooLong = String(repeating: "a", count: GmailMessage.maxHeaderLineLength) + ".pdf"
        #expect(MailAttachment(filename: tooLong, mimeType: "application/pdf", data: pdfBytes) == nil)
    }

    @Test func aFilenameWhoseLengthIsOnlyReachedOncePercentEncodedIsRefusedToo() {
        // Well under the limit as characters, well over it once each one is nine characters of
        // percent encoding. A check on the name's length alone accepts this.
        let accented = String(repeating: "é", count: GmailMessage.maxHeaderLineLength / 4) + ".pdf"
        #expect(accented.count < GmailMessage.maxHeaderLineLength)
        #expect(MailAttachment(filename: accented, mimeType: "application/pdf", data: pdfBytes) == nil)
    }

    @Test func aFilenameOfOrdinaryLengthIsNotRefused() {
        let ordinary = String(repeating: "a", count: 100) + ".pdf"
        #expect(MailAttachment(filename: ordinary, mimeType: "application/pdf", data: pdfBytes) != nil)
    }

    // ---------------------------------------------------------------------------------------
    // WHAT A FILENAME CANNOT DO. It reaches a header, so it goes through the same treatment every
    // other header value here goes through, and a test per escape route.

    @Test func aFilenameCarryingALineBreakCannotStartAHeader() throws {
        let sneaky = MailAttachment(filename: "ok.pdf\r\nBcc: someone@example.com",
                                    mimeType: "application/pdf", data: pdfBytes)!
        let part = try message(attachments: [sneaky]).parts[1]
        #expect(part.header("Bcc") == nil)
        #expect(part.dispositionFilename?.contains("Bcc") == true)
        #expect(part.dispositionFilename?.contains("\r") == false)
        #expect(part.dispositionFilename?.contains("\n") == false)
    }

    @Test func aFilenameCarryingAQuoteStaysInsideItsParameter() throws {
        let sneaky = MailAttachment(filename: #"a".pdf"#, mimeType: "application/pdf", data: pdfBytes)!
        let part = try message(attachments: [sneaky]).parts[1]
        #expect(part.dispositionFilename == #"a".pdf"#)
        #expect(part.disposition == "attachment")
    }

    @Test func aNonASCIIFilenameArrivesAsItself() throws {
        let cafe = MailAttachment(filename: "Café note.pdf", mimeType: "application/pdf", data: pdfBytes)!
        let part = try message(attachments: [cafe]).parts[1]
        #expect(part.dispositionFilename == "Café note.pdf")
        // Percent encoded on the wire, because a header has to stay seven bit clean.
        let raw = GmailMessage.rfc822(fromName: "S", fromEmail: "s@example.com", to: ["c@example.com"],
                                      subject: "S", body: "b", attachments: [cafe])
        #expect(raw.allSatisfy { $0.isASCII })
    }

    // ---------------------------------------------------------------------------------------
    // WHAT CANNOT BE CONSTRUCTED. Each of these would reach a recipient as a defect rather than a
    // refusal: an unnamed blob, an empty file where a document was meant to be, or a content type
    // that carries a second parameter into the header (L67, L150).

    @Test func anEmptyFileIsNotAnAttachment() {
        #expect(MailAttachment(filename: "empty.pdf", mimeType: "application/pdf", data: Data()) == nil)
    }

    @Test func anUnnamedFileIsNotAnAttachment() {
        #expect(MailAttachment(filename: "   ", mimeType: "application/pdf", data: pdfBytes) == nil)
    }

    @Test func aContentTypeThatIsNotOneTypeAndOneSubtypeIsRefused() {
        for bad in ["application/pdf; name=\"x\"", "applicationpdf", "application/", "/pdf",
                    "application/pdf\r\nBcc: x", "", "application / pdf"] {
            #expect(MailAttachment(filename: "a.pdf", mimeType: bad, data: pdfBytes) == nil,
                    "\(bad) should not be accepted as a content type")
        }
    }

    @Test func anOrdinaryContentTypeIsAccepted() {
        for good in ["application/pdf", "text/plain", "image/jpeg", "application/vnd.ms-excel",
                     "APPLICATION/PDF"] {
            #expect(MailAttachment(filename: "a", mimeType: good, data: pdfBytes) != nil,
                    "\(good) should be accepted as a content type")
        }
    }

    // ---------------------------------------------------------------------------------------
    // THE MAIL ITSELF

    @Test func aMailCarriesNoAttachmentsUnlessItIsGivenSome() throws {
        let mail = try #require(OutgoingMail(to: ["c@example.com"], subject: "s", body: "b"))
        #expect(mail.attachments.isEmpty)
    }

    @Test func aMailKeepsTheAttachmentsItWasGiven() throws {
        let mail = try #require(OutgoingMail(to: ["c@example.com"], subject: "s", body: "b",
                                             attachments: [invoice]))
        #expect(mail.attachments == [invoice])
    }
}
