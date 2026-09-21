import Foundation
import Testing
@testable import BackstageGoogle

// Asking whether a mail will fit, before anybody presses send. backstage#54.
//
// The refusal that already exists speaks only when a send is attempted, which is after the point
// where the person who chose the file has moved on. This is the same measurement asked as a
// question, and the ONE THING THAT MATTERS about it is that it is the same measurement: a
// prediction computed a second way is a number that agrees with the refusal until the day it does
// not, and nothing would say which of the two was wrong (L70).
@MainActor
struct MailFitsTests {

    private let limit = GmailSendLimits.maxRequestBytes

    private func mail(attachmentBytes: Int) throws -> OutgoingMail {
        let file = try #require(MailAttachment(filename: "invoice.pdf", mimeType: "application/pdf",
                                               data: Data(repeating: 0x41, count: attachmentBytes)))
        return try #require(OutgoingMail(to: ["client@example.com"], subject: "Invoice 1042",
                                         body: "Attached.", attachments: [file]))
    }

    // A sender whose token and fetch both RECORD being reached, so a measurement that quietly did
    // network work or asked for a login fails rather than merely being slower than it looks.
    final class Reached: @unchecked Sendable {
        var tokenCalls = 0
        var fetchCalls = 0
    }

    private func sender(signature: MessageSignature = .none,
                        reached: Reached = Reached()) -> GmailSender {
        GmailSender(fromName: "Sender", fromEmail: "sender@example.com", signature: signature,
                    token: { reached.tokenCalls += 1; return "tok" },
                    fetch: { _ in
                        reached.fetchCalls += 1
                        throw URLError(.notConnectedToInternet)
                    },
                    onAuthExpired: {})
    }

    @Test func aMailThatFitsSaysSo() throws {
        let measured = try sender().measure(try mail(attachmentBytes: limit / 2))
        #expect(measured.fits)
        #expect(measured.limitBytes == limit)
        #expect(measured.encodedBytes <= limit)
    }

    @Test func aMailThatDoesNotFitSaysSo() throws {
        let measured = try sender().measure(try mail(attachmentBytes: limit))
        #expect(!measured.fits)
        #expect(measured.encodedBytes > limit)
    }

    // THE WHOLE POINT. The number a consumer shows before the send and the number the refusal
    // reports after it must be one number, or a screen says a file fits and the send says it does
    // not.
    @Test func theNumberMeasuredIsTheNumberTheRefusalReports() async throws {
        let tooBig = try mail(attachmentBytes: limit)
        let measured = try sender().measure(tooBig)
        do {
            _ = try await sender().send(tooBig)
            Issue.record("the oversize mail was not refused")
        } catch GmailSendError.tooLarge(let encodedBytes, let limitBytes) {
            #expect(encodedBytes == measured.encodedBytes)
            #expect(limitBytes == measured.limitBytes)
        }
    }

    // ASKING COSTS NOTHING OUTSIDE THE PROCESS. A measurement that reached for a token would make
    // a control that merely warns do a round trip to Google every time somebody attaches a file.
    @Test func measuringReachesNoNetworkAndAsksForNoToken() throws {
        let reached = Reached()
        _ = try sender(reached: reached).measure(try mail(attachmentBytes: 1_000))
        #expect(reached.tokenCalls == 0)
        #expect(reached.fetchCalls == 0)
    }

    // AND THE REFUSAL COMES BEFORE THE LOGIN (backstage#56). The size needs no token to measure, so
    // an oversize message must not cost a round trip to Google on the way to being turned away. A
    // refusal placed after a step it does not depend on makes the rare leftover happen on every
    // ordinary refused attempt (L667).
    @Test func anOversizeMailIsRefusedWithoutAskingForAToken() async throws {
        let reached = Reached()
        await #expect(throws: GmailSendError.self) {
            _ = try await self.sender(reached: reached).send(try self.mail(attachmentBytes: self.limit))
        }
        #expect(reached.tokenCalls == 0)
        #expect(reached.fetchCalls == 0)
    }

    // AND A MAIL THAT FITS STILL GETS ITS TOKEN, or the reordering would have refused everything
    // rather than refusing early: a test that something did NOT happen is satisfied by a fixture
    // where it COULD not (L159).
    @Test func aMailThatFitsStillAsksForItsToken() async throws {
        let reached = Reached()
        _ = try? await sender(reached: reached).send(try mail(attachmentBytes: 1_000))
        #expect(reached.tokenCalls == 1)
        #expect(reached.fetchCalls == 1)
    }

    // THE SIGNATURE IS PART OF WHAT SENDS, so it is part of what is measured. An HTML signature
    // adds a whole second copy of the body, which is exactly the sort of weight a measurement
    // taken from the mail alone would miss.
    @Test func theSendersOwnSignatureIsCounted() throws {
        let one = try mail(attachmentBytes: 1_000)
        let plain = try sender().measure(one)
        let styled = try sender(signature: MessageSignature(plainText: "Best", html: "<p>Best</p>"))
            .measure(one)
        #expect(styled.encodedBytes > plain.encodedBytes)
    }

    // THE BOUNDARY, pinned without needing a file of exactly the right size, which cannot be built
    // to the byte through three layers of encoding.
    @Test func exactlyTheLimitFitsAndOneByteMoreDoesNot() {
        #expect(MailSizeMeasurement(encodedBytes: limit, limitBytes: limit).fits)
        #expect(!MailSizeMeasurement(encodedBytes: limit + 1, limitBytes: limit).fits)
    }

    // A SENDER THAT CANNOT SEND CANNOT ANSWER THE QUESTION EITHER, and says the same thing it says
    // about sending rather than inventing a number for a route nothing can take.
    @Test func aSenderWithNoAccountRefusesToMeasureAsWellAsToSend() throws {
        #expect(throws: MailSenderError.notConfigured) {
            try NotConfiguredSender().measure(try self.mail(attachmentBytes: 1_000))
        }
    }
}
