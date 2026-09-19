import Foundation
import Testing
@testable import BackstageGoogle

// The shape of a mail to send and of a receipt for one sent. backstage#2.
struct MailSenderTests {

    @Test func aMailWithNobodyToSendToCannotBeMade() {
        #expect(OutgoingMail(to: [], subject: "s", body: "b") == nil)
        #expect(OutgoingMail(to: ["  ", ""], subject: "s", body: "b") == nil)
    }

    @Test func aBlankBesideARealAddressIsDroppedNotRefused() {
        let mail = OutgoingMail(to: ["a@example.com", " "], subject: "s", body: "b")
        #expect(mail?.to == ["a@example.com"])
    }

    @Test func aMailWithABlankSubjectCannotBeMade() {
        #expect(OutgoingMail(to: ["a@example.com"], subject: "   ", body: "b") == nil)
    }

    // What the person approved is what sends: the subject is not trimmed, only checked.
    @Test func theSubjectIsKeptVerbatim() {
        #expect(OutgoingMail(to: ["a@example.com"], subject: " Hello ", body: "b")?.subject == " Hello ")
    }

    @Test func referencesChainOldestFirst() {
        #expect(MailThreading.references(parentReferences: "<a@x>", parentMessageID: "<b@x>") == "<a@x> <b@x>")
        #expect(MailThreading.references(parentReferences: nil, parentMessageID: "<b@x>") == "<b@x>")
        #expect(MailThreading.references(parentReferences: " ", parentMessageID: nil) == nil)
    }

    // The default sender refuses rather than sending, so nothing leaves by accident.
    @Test func theUnconfiguredSenderRefuses() async {
        let mail = OutgoingMail(to: ["a@example.com"], subject: "s", body: "b")!
        await #expect(throws: MailSenderError.notConfigured) {
            _ = try await NotConfiguredSender().send(mail)
        }
    }

    // THE PACKAGE CARRIES NO CONSUMER'S VOICE. The origin's message named its own account; this one
    // is shown by three apps and may say only what is true of all of them.
    @Test func theRefusalSaysNothingAboutAnyOneApp() {
        let message = MailSenderError.notConfigured.errorDescription ?? ""
        #expect(message.contains("Gmail"))
        #expect(!message.lowercased().contains("photograph"))
    }
}
