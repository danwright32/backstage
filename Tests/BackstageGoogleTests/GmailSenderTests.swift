import Foundation
import Testing
@testable import BackstageGoogle

// Sending through the Gmail API, with every outside dependency handed in, so no test reaches the
// network or a real login (L2). backstage#2 step 3.
@MainActor
struct GmailSenderTests {

    // A scripted fetch: answers each request in turn and remembers what it was asked.
    final class Script: @unchecked Sendable {
        var answers: [(Int, String)]
        var requests: [URLRequest] = []
        var authExpiredCalls = 0
        init(_ answers: [(Int, String)]) { self.answers = answers }
        func fetch(_ req: URLRequest) throws -> (Data, URLResponse) {
            requests.append(req)
            guard !answers.isEmpty else { throw URLError(.notConnectedToInternet) }
            let (status, body) = answers.removeFirst()
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), resp)
        }
    }

    private let mail = OutgoingMail(to: ["client@example.com"], subject: "Invoice 1042", body: "Attached.")!
    private let sentBody = #"{"id":"m1","threadId":"t1"}"#
    private let readBack = #"{"payload":{"headers":[{"name":"Message-Id","value":"<real@example.com>"}]}}"#

    private func send(_ script: Script, mail: OutgoingMail? = nil,
                      signature: MessageSignature = .none) async throws -> SentReceipt {
        try await GmailSender.performSend(
            body: try GmailSender.encodedRequestBody(
                mail: mail ?? self.mail, fromName: "Sender", fromEmail: "sender@example.com",
                signature: signature),
            token: "tok",
            fetch: { try script.fetch($0) },
            onAuthExpired: { script.authExpiredCalls += 1 })
    }

    private func decodedRaw(_ req: URLRequest) throws -> String {
        let json = try JSONSerialization.jsonObject(with: try #require(req.httpBody)) as? [String: Any]
        var b64 = try #require(json?["raw"] as? String)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return String(data: try #require(Data(base64Encoded: b64)), encoding: .utf8) ?? ""
    }

    @Test func aSuccessfulSendReturnsTheThreadAndTheRealMessageID() async throws {
        let script = Script([(200, sentBody), (200, readBack)])
        let receipt = try await send(script)
        #expect(receipt == SentReceipt(threadId: "t1", messageID: "<real@example.com>"))

        let post = script.requests[0]
        #expect(post.httpMethod == "POST")
        #expect(post.url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")
        #expect(post.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(try decodedRaw(post).contains("Subject: Invoice 1042"))
    }

    @Test func theSignatureTheConsumerGivesIsTheOneThatSends() async throws {
        let script = Script([(200, sentBody), (200, readBack)])
        _ = try await send(script, signature: MessageSignature(plainText: "Regards", html: "<p>Regards</p>"))
        let raw = try decodedRaw(script.requests[0])
        #expect(raw.contains("multipart/alternative"))
        #expect(raw.contains("<p>Regards</p>"))
    }

    // backstage#51: the attachment is on the MAIL and the signature is on the SENDER, so the wire
    // form is decided from two places. This is the one test that walks the whole way from an
    // OutgoingMail to the bytes posted, decoded rather than matched as a string (L52).
    @Test func anAttachmentOnTheMailReachesTheWire() async throws {
        let script = Script([(200, sentBody), (200, readBack)])
        let file = try #require(MailAttachment(filename: "invoice.pdf", mimeType: "application/pdf",
                                               data: Data([0x25, 0x50, 0x44, 0x46, 0x00, 0xFF])))
        let withFile = try #require(OutgoingMail(to: ["client@example.com"], subject: "Invoice 1042",
                                                 body: "Attached.", attachments: [file]))
        _ = try await send(script, mail: withFile,
                           signature: MessageSignature(plainText: "Best", html: "<p>Best</p>"))
        let posted = try MIMEReader.parse(try decodedRaw(script.requests[0]))
        #expect(posted.contentType == "multipart/mixed")
        #expect(posted.parts.map(\.contentType) == ["multipart/alternative", "application/pdf"])
        #expect(posted.parts[1].dispositionFilename == "invoice.pdf")
        #expect(posted.parts[1].body == file.data)
    }

    @Test func aReplyCarriesItsThreadToGmail() async throws {
        let script = Script([(200, sentBody), (200, readBack)])
        let reply = OutgoingMail(to: ["c@example.com"], subject: "Re", body: "b", threadId: "t9")!
        _ = try await send(script, mail: reply)
        let json = try JSONSerialization.jsonObject(with: try #require(script.requests[0].httpBody)) as? [String: Any]
        #expect(json?["threadId"] as? String == "t9")
    }

    // A 401 is a dead login: the consumer is told, so it can show disconnected.
    @Test func aRevokedTokenSignalsAuthExpired() async {
        let script = Script([(401, "unauthorized")])
        await #expect(throws: GmailSendError.authExpired) { _ = try await send(script) }
        #expect(script.authExpiredCalls == 1)
    }

    // A 403 is NOT a dead login. Gmail uses it for rate limits and permissions, which reconnecting
    // will not fix, and signing somebody out mid batch over one is the costly direction.
    @Test func aRefusalThatIsNotADeadLoginDoesNotSignAnybodyOut() async {
        let script = Script([(403, "rate limited")])
        await #expect(throws: GmailSendError.api("rate limited")) { _ = try await send(script) }
        #expect(script.authExpiredCalls == 0)
    }

    @Test func aServerErrorIsReportedWithItsDetail() async {
        let script = Script([(500, "backend error")])
        await #expect(throws: GmailSendError.api("backend error")) { _ = try await send(script) }
    }

    // The send succeeded, so it must never throw, but a reply with no thread must say so rather
    // than come back looking complete.
    @Test func aSendWithNoReadableThreadComesBackFlagged() async throws {
        let script = Script([(200, "{}"), (200, readBack)])
        let receipt = try await send(script)
        #expect(receipt.threadId == "")
        #expect(receipt.threadIdDegraded)
    }

    // The mail has GONE by the time the read back runs, so failing to read the id back must never be
    // reported as failing to send. It comes back flagged instead, never with a guessed id.
    @Test func aFailedReadBackFlagsTheReceiptAndNeverThrows() async throws {
        let script = Script([(200, sentBody)])   // the second request finds nothing and throws
        let receipt = try await send(script)
        #expect(receipt.threadId == "t1")
        #expect(receipt.messageID == nil)
        #expect(receipt.messageIDDegraded)
    }

    // The token provider the consumer supplies is what the send uses, and a failure there stops
    // the send before anything is posted.
    @Test func aTokenFailureStopsTheSendBeforeAnythingIsPosted() async {
        let script = Script([(200, sentBody)])
        let sender = GmailSender(fromName: "Sender", fromEmail: "sender@example.com",
                                 token: { throw GmailSendError.authExpired },
                                 fetch: { try script.fetch($0) },
                                 onAuthExpired: {})
        await #expect(throws: GmailSendError.authExpired) { _ = try await sender.send(self.mail) }
        #expect(script.requests.isEmpty)
    }

    // THE PACKAGE CARRIES NO CONSUMER'S VOICE: no app's control is named in its messages.
    @Test func theExpiredMessageNamesNoAppsControl() {
        let message = GmailSendError.authExpired.errorDescription ?? ""
        #expect(!message.lowercased().contains("click"))
        #expect(message.contains("Gmail"))
    }
}
