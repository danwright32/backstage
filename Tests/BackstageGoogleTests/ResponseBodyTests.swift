import Foundation
import Testing
@testable import BackstageGoogle

// Reading a response body that ARRIVED, keeping "I could not understand this"
// apart from "there was nothing in it". backstage#2.
//
// It is vendored because GoogleOAuth.interpretRefreshResponse calls it, and it
// is worth a test here because the whole point of it is that an unreadable body
// is RECORDED rather than swallowed by a `try?`.
struct ResponseBodyTests {

    @Test func aGoodBodyDecodes() {
        struct Payload: Codable, Equatable { var name: String }
        let recorder = ResponseDecodeFailures()
        let read = ResponseBody.decode(Payload.self, from: Data(#"{"name":"x"}"#.utf8),
                                       endpoint: "test.endpoint", recorder: recorder)
        #expect(read.value == Payload(name: "x"))
    }

    // THE POINT OF THE FILE. An unreadable body yields no value AND leaves a
    // record, so the failure has a surface instead of vanishing.
    @Test func anUnreadableBodyYieldsNothingAndIsRecorded() {
        struct Payload: Codable { var name: String }
        let recorder = ResponseDecodeFailures()
        let read = ResponseBody.decode(Payload.self, from: Data("not json".utf8),
                                       endpoint: "test.endpoint", recorder: recorder)

        #expect(read.value == nil)
        if case .undecodable(let reason) = read {
            #expect(!reason.isEmpty, "a recorded failure with no reason cannot be acted on")
        } else {
            Issue.record("expected undecodable, got a decoded value")
        }
    }

    // An EMPTY body is not a different question from an unreadable one here: it
    // still decodes to nothing, and it still must not read as a successful empty
    // result (L215).
    @Test func anEmptyBodyIsUndecodableRatherThanEmpty() {
        struct Payload: Codable { var name: String }
        let recorder = ResponseDecodeFailures()
        let read = ResponseBody.decode(Payload.self, from: Data(), endpoint: "test.endpoint",
                                       recorder: recorder)
        #expect(read.value == nil)
    }
}
