import Foundation
import Testing
@testable import BackstageGoogle

// The decode tally has a READER (backstage#12).
//
// ResponseBody records every response body it could not decode, with the
// endpoint and a reason. Nothing in this package read that tally, so the
// recording was real work producing a record with no consumer, which is the
// shape that reads as observability and provides none (L46).
//
// EVERY CASE DRIVES ITS OWN REGISTER, never the shared one. A test reading or
// writing the register another test is using is a test whose result depends on
// what else ran (L2), and the injectable register exists for exactly that.
struct ResponseDecodeHealthTests {

    private struct Payload: Codable { var name: String }

    private func read(_ body: String, from endpoint: String,
                      into register: ResponseDecodeFailures) {
        _ = ResponseBody.decode(Payload.self, from: Data(body.utf8),
                                endpoint: endpoint, recorder: register)
    }

    // THE CASE THE ISSUE ASKS FOR: two unreadable bodies for one endpoint and
    // one for another, read back through the exposed surface.
    @Test func theReadingNamesEveryEndpointThatFailedAndCountsEach() {
        let register = ResponseDecodeFailures()
        let health = ResponseDecodeHealth(register: register)

        read("not json", from: "oauth.token", into: register)
        read("still not json", from: "oauth.token", into: register)
        read("nor this", from: "gmail.send", into: register)

        let reading = health.current()
        #expect(reading.map(\.endpoint) == ["gmail.send", "oauth.token"])
        #expect(reading.first { $0.endpoint == "oauth.token" }?.failures == 2)
        #expect(reading.first { $0.endpoint == "gmail.send" }?.failures == 1)
    }

    // A SUCCESSFUL DECODE IS NOT TROUBLE, so it does not appear. A reading that
    // listed every endpoint the app has ever called is not something anybody
    // reads, and the one line that matters would be buried in it.
    @Test func anEndpointThatHasOnlySucceededIsNotInTheReading() {
        let register = ResponseDecodeFailures()
        let health = ResponseDecodeHealth(register: register)

        read(#"{"name":"x"}"#, from: "gmail.profile", into: register)
        read("not json", from: "oauth.token", into: register)

        #expect(health.current().map(\.endpoint) == ["oauth.token"])
    }

    // THE REASON TRAVELS WITH THE COUNT. A count with no reason cannot be acted
    // on, and it is the reason that says whether this is Google answering badly
    // or this package asking for a field that moved (L148).
    @Test func theReadingCarriesWhyTheLastOneCouldNotBeRead() {
        let register = ResponseDecodeFailures()
        let health = ResponseDecodeHealth(register: register)

        read("not json at all", from: "oauth.token", into: register)

        let reason = health.current().first?.lastReason
        #expect(reason?.isEmpty == false)
    }

    // A RUN OF FAILURES IS THE CONDITION, and the threshold the package judges
    // by is exposed beside the reading, so a consumer showing "2 of 3" is
    // reading the same number the package is.
    @Test func aRunOfFailuresIsNamedAsFailingAndOneIsNot() {
        let register = ResponseDecodeFailures()
        let health = ResponseDecodeHealth(register: register)

        read("bad", from: "oauth.token", into: register)
        #expect(health.failing().isEmpty)
        #expect(health.current().first?.isFailing == false)

        for _ in 0..<(ResponseDecodeHealth.failingRun - 1) {
            read("bad", from: "oauth.token", into: register)
        }
        #expect(health.failing().map(\.endpoint) == ["oauth.token"])
    }

    // THE RUN ENDS ON A SUCCESS AND ON NOTHING ELSE, and the totals survive it,
    // because they are what says this endpoint has been unhealthy today. A
    // reading cleared on recovery could not answer that (L160).
    @Test func aSuccessEndsTheRunAndKeepsTheTotals() {
        let register = ResponseDecodeFailures()
        let health = ResponseDecodeHealth(register: register)

        for _ in 0..<ResponseDecodeHealth.failingRun {
            read("bad", from: "oauth.token", into: register)
        }
        #expect(health.failing().map(\.endpoint) == ["oauth.token"])

        read(#"{"name":"x"}"#, from: "oauth.token", into: register)

        #expect(health.failing().isEmpty)
        let reading = health.current().first
        #expect(reading?.consecutiveFailures == 0)
        #expect(reading?.failures == ResponseDecodeHealth.failingRun)
        #expect(reading?.attempts == ResponseDecodeHealth.failingRun + 1)
    }

    // AN ENDPOINT NOBODY HAS CALLED IS AN EMPTY READING, not a missing one. A
    // consumer showing a status line needs to be able to tell "nothing has gone
    // wrong" from "this could not be read" (L10).
    @Test func aRegisterNothingHasBeenRecordedIntoReadsEmpty() {
        let health = ResponseDecodeHealth(register: ResponseDecodeFailures())
        #expect(health.current().isEmpty)
        #expect(health.failing().isEmpty)
    }
}
