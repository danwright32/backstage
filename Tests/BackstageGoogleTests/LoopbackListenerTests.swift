import Foundation
import Network
import Testing
@testable import BackstageGoogle

// The local server that catches Google's redirect back to the app. backstage#2.
struct LoopbackListenerTests {

    // A bind refused for now is worth another attempt; anything else is reported at once, because
    // retrying a permanent failure spends the person's whole wait to reach the same answer (L110).
    @Test func onlyMomentaryBindFailuresAreRetried() {
        #expect(LoopbackListener.isTransientBindFailure(.posix(.EADDRNOTAVAIL)))
        #expect(LoopbackListener.isTransientBindFailure(.posix(.EADDRINUSE)))
        #expect(!LoopbackListener.isTransientBindFailure(.posix(.EACCES)))
    }

    // A negative budget handed to a sleep or a timeout reads as no limit at all.
    @Test func theRemainingBudgetIsNeverNegative() {
        #expect(LoopbackListener.remainingBudget(deadline: 10, now: 4) == 6)
        #expect(LoopbackListener.remainingBudget(deadline: 10, now: 15) == 0)
    }

    // A real bind, on the loopback address only, which touches nothing outside this machine. The
    // ceiling is deliberately far above the shipped ten seconds: under a loaded test run the readiness
    // callback can be late by a long way, and a test at the shipped value would measure the machine
    // rather than the listener (L290).
    @Test func itBindsARealPortOnTheLoopbackAddress() async throws {
        let (listener, port) = try await LoopbackListener.start(
            queue: DispatchQueue(label: "backstage.loopback.test"), timeout: 120) { $0.cancel() }
        defer { listener.cancel() }
        #expect(port != 0, "a port read before the listener is ready is zero, which the browser cannot reach")
    }
}
