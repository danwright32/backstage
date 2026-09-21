import Foundation
import Testing
@testable import BackstageGoogle

// The size refusal, backstage#51.
//
// MEASURED ON THE ENCODED REQUEST, never on the attachment's own byte count, because those are not
// the same number and it is the first one Gmail applies (L81). A PDF grows roughly four fifths on
// the way to the wire: base64 into its own part, wrapped at 76, then the whole RFC822 message
// base64url encoded into `raw`, then JSON escaped. A refusal written against the file's size admits
// a file that arrives over the limit and gets exactly the opaque 400 the refusal exists to prevent,
// while reading as protection (L63).
//
// EVERY FIXTURE IS DERIVED FROM THE LIMIT CONSTANT rather than written as a literal at its edge, so
// the day that constant moves these still ask the question they were written to ask (L401).
@MainActor
struct MailSizeRefusalTests {

    private let limit = GmailSendLimits.maxRequestBytes

    final class Script: @unchecked Sendable {
        var requests: [URLRequest] = []
        var answers: [(Int, String)]
        init(_ answers: [(Int, String)]) { self.answers = answers }
        func fetch(_ req: URLRequest) throws -> (Data, URLResponse) {
            requests.append(req)
            guard !answers.isEmpty else { throw URLError(.notConnectedToInternet) }
            let (status, body) = answers.removeFirst()
            return (Data(body.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func mail(attachmentBytes: Int) throws -> OutgoingMail {
        let file = try #require(MailAttachment(filename: "invoice.pdf", mimeType: "application/pdf",
                                               data: Data(repeating: 0x41, count: attachmentBytes)))
        return try #require(OutgoingMail(to: ["client@example.com"], subject: "Invoice 1042",
                                         body: "Attached.", attachments: [file]))
    }

    private func send(_ mail: OutgoingMail, _ script: Script) async throws -> SentReceipt {
        try await GmailSender.performSend(
            mail: mail, fromName: "Sender", fromEmail: "sender@example.com", token: "tok",
            fetch: { try script.fetch($0) }, onAuthExpired: {})
    }

    // HALF THE LIMIT OF FILE reaches roughly nine tenths of the limit encoded, which is the point of
    // the whole rule: a file comfortably under the cap is nearly over it by the time it is a request.
    @Test func aFileAtHalfTheLimitIsAlreadyNearlyTheWholeRequest() throws {
        let encoded = try GmailSender.encodedRequestBody(
            mail: try mail(attachmentBytes: limit / 2), fromName: "Sender",
            fromEmail: "sender@example.com", signature: .none)
        #expect(encoded.count > limit * 3 / 4)
        #expect(encoded.count <= limit)
    }

    @Test func aMailThatFitsOnceEncodedIsSent() async throws {
        let script = Script([(200, #"{"id":"m1","threadId":"t1"}"#), (200, "{}")])
        let receipt = try await send(try mail(attachmentBytes: limit / 2), script)
        #expect(receipt.threadId == "t1")
        #expect(script.requests.count == 2)
    }

    @Test func aMailOverTheLimitOnceEncodedIsRefused() async throws {
        let script = Script([(200, #"{"id":"m1","threadId":"t1"}"#)])
        await #expect(throws: GmailSendError.self) {
            _ = try await send(try mail(attachmentBytes: limit), script)
        }
        // NOTHING WAS SENT. A refusal that still posts the request has refused nothing.
        #expect(script.requests.isEmpty)
    }

    @Test func theRefusalNamesBothNumbersAndWhyTheyDiffer() async throws {
        let script = Script([])
        do {
            _ = try await send(try mail(attachmentBytes: limit), script)
            Issue.record("a mail over the limit was not refused")
        } catch let error as GmailSendError {
            guard case .tooLarge(let encodedBytes, let limitBytes) = error else {
                Issue.record("refused with \(error) rather than tooLarge")
                return
            }
            #expect(limitBytes == limit)
            #expect(encodedBytes > limit)
            let said = try #require(error.errorDescription)
            // BOTH NUMBERS AND THE REASON THEY DIFFER. Rendered here from the values the error
            // carries rather than written as literals, so this keeps asking its question when the
            // limit moves (L401). Without the third assertion the message accuses a 5 MB file of
            // being 9 MB and reads as a fault in the file.
            func megabytes(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }
            #expect(said.contains(megabytes(encodedBytes)))
            #expect(said.contains(megabytes(limitBytes)))
            #expect(said.lowercased().contains("grow"))
        }
    }

    // THE LIMIT IS THE ONE GMAIL APPLIES, and a message with no attachment at all is nowhere near
    // it, so the ordinary send is not paying for this.
    @Test func anOrdinaryMailIsNowhereNearTheLimit() throws {
        let plain = try #require(OutgoingMail(to: ["c@example.com"], subject: "s", body: "b"))
        let encoded = try GmailSender.encodedRequestBody(
            mail: plain, fromName: "S", fromEmail: "s@example.com", signature: .none)
        #expect(encoded.count < limit / 100)
    }
}
