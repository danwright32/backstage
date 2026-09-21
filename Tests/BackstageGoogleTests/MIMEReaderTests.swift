import Foundation
import Testing
@testable import BackstageGoogle

// THE READER IS PROVED AGAINST A MESSAGE THIS REPOSITORY DID NOT PRODUCE, and that is the whole
// reason this file exists before the attachment tests that use it.
//
// backstage#51 asks for a round trip: decode what GmailMessage produced and assert the parts came
// back intact. A decoder written alongside the producer can share the producer's misreading of the
// standard and agree with it for ever, which is a test confirming its author's own assumption
// rather than the wire form (L52). So the reader is calibrated here against a message written by
// hand from RFC 2045 and 2046, carrying the shapes a real message carries and this repository's
// producer happens not to emit: a preamble before the first boundary, an epilogue after the
// closing one, a folded header continued on the next line, a base64 body wrapped at 76, and bytes
// that are not text.
struct MIMEReaderTests {

    // Hand authored. NOT produced by GmailMessage, and deliberately not shaped like its output.
    private let handWritten = [
        "From: A Person <a@example.com>",
        "To: b@example.com",
        "Subject: Hand written",
        "MIME-Version: 1.0",
        "Content-Type: multipart/mixed; boundary=\"OUTER\"",
        "",
        "A preamble. A reader that does not drop this reports it as a part.",
        "--OUTER",
        "Content-Type: multipart/alternative; boundary=\"INNER\"",
        "",
        "--INNER",
        "Content-Type: text/plain; charset=UTF-8",
        "Content-Transfer-Encoding: 8bit",
        "",
        "Hello there",
        "--INNER",
        "Content-Type: text/html; charset=UTF-8",
        "Content-Transfer-Encoding: 8bit",
        "",
        "<p>Hello there</p>",
        "--INNER--",
        "--OUTER",
        // Folded across two lines, which is how a long parameter list reaches a real inbox.
        "Content-Type: application/pdf;",
        "\tname=\"note.pdf\"",
        "Content-Transfer-Encoding: base64",
        "Content-Disposition: attachment; filename=\"note.pdf\"",
        "",
        "JVBERi0xLjQKAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4v",
        "MDEyMw==",
        "--OUTER--",
        "An epilogue, which is not a part either.",
    ].joined(separator: "\r\n")

    // The bytes the base64 above stands for: a text prefix, a NUL, and a run climbing past 0x7F,
    // so a reader that went through a String somewhere loses them and says so.
    private var handWrittenBytes: Data {
        Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A] + Array(UInt8(0)...UInt8(51)))
    }

    @Test func itReadsTheStructureOfAMessageItDidNotProduce() throws {
        let m = try MIMEReader.parse(handWritten)
        #expect(m.contentType == "multipart/mixed")
        #expect(m.header("Subject") == "Hand written")
        #expect(m.parts.count == 2)
        #expect(m.parts[0].contentType == "multipart/alternative")
        #expect(m.parts[0].parts.map(\.contentType) == ["text/plain", "text/html"])
        #expect(m.parts[1].contentType == "application/pdf")
    }

    @Test func aPreambleAndAnEpilogueAreNotParts() throws {
        let m = try MIMEReader.parse(handWritten)
        #expect(m.parts.count == 2)
        #expect(!m.parts.contains { $0.text.contains("preamble") || $0.text.contains("epilogue") })
    }

    @Test func aFoldedHeaderIsOneHeader() throws {
        let attachment = try MIMEReader.parse(handWritten).parts[1]
        #expect(attachment.parameters["name"] == "note.pdf")
        #expect(attachment.header("Content-Disposition") == "attachment; filename=\"note.pdf\"")
    }

    @Test func aWrappedBase64BodyComesBackAsItsBytes() throws {
        let attachment = try MIMEReader.parse(handWritten).parts[1]
        #expect(attachment.body == handWrittenBytes)
    }

    @Test func anEightBitPartComesBackAsItsText() throws {
        let alternative = try MIMEReader.parse(handWritten).parts[0]
        #expect(alternative.parts[0].text == "Hello there")
        #expect(alternative.parts[1].text == "<p>Hello there</p>")
    }

    // A SINGLE PART MESSAGE IS NOT A MULTIPART WITH ONE PART. Asserted because the attachment
    // tests read `parts.isEmpty` as "this message carries no separate parts", and a reader that
    // wrapped every body in a synthetic part would make that assertion unfalsifiable.
    @Test func aSinglePartMessageHasNoParts() throws {
        let m = try MIMEReader.parse([
            "Subject: Plain",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            "Just a body",
        ].joined(separator: "\r\n"))
        #expect(m.contentType == "text/plain")
        #expect(m.parts.isEmpty)
        #expect(m.text == "Just a body")
    }

    // A MULTIPART WHOSE BOUNDARY NEVER APPEARS IS A REFUSAL, never an empty part list: an empty
    // list would let a producer that forgot to write its parts pass every "the parts are right"
    // assertion by having none of them (L98).
    @Test func aMultipartWithNoBoundaryLineIsRefusedRatherThanReadAsEmpty() {
        let broken = [
            "Content-Type: multipart/mixed; boundary=\"OUTER\"",
            "",
            "nothing here opens a part",
        ].joined(separator: "\r\n")
        #expect(throws: MIMEReader.Failure.self) { try MIMEReader.parse(broken) }
    }

    // RFC 2231: a non-ASCII filename travels percent encoded with its charset named, which is what
    // the producer emits and what this has to be able to read back.
    @Test func anRFC2231ParameterIsDecoded() throws {
        let m = try MIMEReader.parse([
            "Content-Type: application/pdf",
            "Content-Transfer-Encoding: base64",
            "Content-Disposition: attachment; filename*=UTF-8''Caf%C3%A9%20note.pdf",
            "",
            "AAA=",
        ].joined(separator: "\r\n"))
        #expect(m.dispositionFilename == "Café note.pdf")
    }

    @Test func aQuotedFilenameIsDecodedToo() throws {
        let attachment = try MIMEReader.parse(handWritten).parts[1]
        #expect(attachment.dispositionFilename == "note.pdf")
    }
}
