import Foundation
import Testing
@testable import BackstageGoogle

// A test run must be structurally unable to reach Google (backstage#5, L2). The refusal lives in the
// PACKAGE, at the one place a live call is made, so every consumer inherits it: putting it in one
// consumer's copy would hand the others an unrefusing client when they migrate.
struct TestRefusalTests {

    // THE DETECTION HAS TO BE MEASURED IN THE REAL HARNESS, not assumed. If this is false the whole
    // refusal is inert and every other test here passes for the wrong reason (L1, L322).
    @Test func thisProcessIsRecognisedAsATestRun() {
        #expect(GmailNetworking.isTestRun())
    }

    @Test func aTestRunIsRefusedByName() {
        let refusal = GmailNetworking.refusal(underTests: true)
        #expect(refusal != nil)
        #expect(refusal?.errorDescription?.contains("test") == true)
    }

    // The positive in the same fixture (L159): outside a test run nothing is refused, so the
    // refusal above is a decision and not a check that refuses everything.
    @Test func aRealRunIsNotRefused() {
        #expect(GmailNetworking.refusal(underTests: false) == nil)
    }

    // THE ENTRY POINT, end to end (L378). A sender built with no fetch of its own uses the live one,
    // and inside a test run that must throw the refusal before any request leaves the machine.
    @MainActor
    @Test func aSenderLeftOnTheLiveNetworkRefusesInsideATestRun() async {
        let sender = GmailSender(fromName: "S", fromEmail: "s@example.com",
                                 token: { "tok" }, onAuthExpired: {})
        let mail = OutgoingMail(to: ["c@example.com"], subject: "s", body: "b")!
        await #expect(throws: GmailNetworking.RefusedUnderTests.self) {
            _ = try await sender.send(mail)
        }
    }
}
