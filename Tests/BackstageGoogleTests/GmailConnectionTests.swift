import Foundation
import Testing
@testable import BackstageGoogle

// The one cached answer to "is Gmail connected?", and the bounded session every call goes through.
// backstage#2.
@MainActor
struct GmailConnectionTests {

    private final class Source { var answer = false; var reads = 0 }

    // A cache that never goes back to the source is the one failure this design could introduce, so
    // it is pinned hardest: the answer changes only when refresh is called, and then it does change.
    @Test func itAnswersFromCacheUntilRefreshedThenGoesBackToTheSource() {
        let source = Source()
        let connection = GmailConnection { source.reads += 1; return source.answer }
        #expect(source.reads == 1)
        #expect(!connection.isConnected)

        source.answer = true
        _ = connection.isConnected
        #expect(source.reads == 1, "reading the cached answer must not touch the source")
        #expect(!connection.isConnected)

        connection.refresh()
        #expect(source.reads == 2)
        #expect(connection.isConnected)
    }

    @Test func refreshedIsConnectedReadsTheSourceEveryTime() {
        let source = Source()
        let connection = GmailConnection { source.reads += 1; return source.answer }
        source.answer = true
        #expect(connection.refreshedIsConnected())
        #expect(source.reads == 2)
    }

    // Every Gmail call is bounded. The platform default waits up to seven days, so a stalled call
    // could hang for a week with nothing to recover it short of a restart.
    @Test func everyCallIsBoundedToThirtySeconds() {
        let config = GmailNetworking.session.configuration
        #expect(config.timeoutIntervalForRequest == 30)
        #expect(config.timeoutIntervalForResource == 30)
    }
}
