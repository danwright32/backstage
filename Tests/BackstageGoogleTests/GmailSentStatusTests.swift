import Foundation
import Testing
@testable import BackstageGoogle

// Did the mailbox actually SEND this message? backstage#2 step 3.
//
// Gmail returns unsent drafts in the same collections as real mail, carrying the sender's own address
// and a newer date, so every attribute but its labels makes a draft look sent. The predicate FAILS
// CLOSED: no label information is "not sent", never a guess (L42, L98). The costly direction is a
// draft wrongly accepted, which would stamp an invoice as sent when it never left.
struct GmailSentStatusTests {

    @Test func aSentMessageIsSent() {
        #expect(GmailSentStatus.wasSentByUser(["labelIds": ["SENT", "INBOX"]]))
    }

    @Test func aDraftIsNeverSentEvenWhenItAlsoCarriesSent() {
        #expect(!GmailSentStatus.wasSentByUser(["labelIds": ["SENT", "DRAFT"]]))
        #expect(!GmailSentStatus.wasSentByUser(["labelIds": ["DRAFT"]]))
    }

    // THE ONE THAT MATTERS: a message with no labels field at all is refused, because missing is
    // Gmail not having been asked, or a shape nobody here has seen, and neither is evidence.
    @Test func noLabelInformationFailsClosed() {
        #expect(!GmailSentStatus.wasSentByUser(["id": "m1"]))
        #expect(GmailSentStatus.labelIds(of: ["id": "m1"]) == nil)
    }

    // Missing and EMPTY are different answers, and the difference is the rule.
    @Test func anEmptyLabelListIsAnAnswerButNotSent() {
        #expect(GmailSentStatus.labelIds(of: ["labelIds": [String]()]) == [])
        #expect(!GmailSentStatus.wasSentByUser(["labelIds": [String]()]))
    }

    @Test func labelsAreComparedAsGmailsOwnConstants() {
        #expect(GmailSentStatus.wasSentByUser(["labelIds": ["sent"]]))
        #expect(GmailSentStatus.isDraft(["labelIds": ["draft"]]))
    }

    @Test func aLabelsFieldOfTheWrongShapeIsNotEvidence() {
        #expect(!GmailSentStatus.wasSentByUser(["labelIds": "SENT"]))
    }
}
