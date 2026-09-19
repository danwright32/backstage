import Foundation
import Network
import Testing
@testable import BackstageGoogle

// The listener's retry schedule, asserted from the delays it ASKED FOR rather than by living
// through them, so no test waits for real (backstage#13, L524).
struct LoopbackRetryTests {

    final class Recorder: @unchecked Sendable {
        var sleeps: [TimeInterval] = []
        var attempts = 0
    }

    private func listener() throws -> NWListener { try NWListener(using: .tcp) }

    @Test func aMomentaryRefusalIsRetriedOnTheStatedSchedule() async throws {
        let rec = Recorder()
        let spare = try listener()
        let (_, port) = try await LoopbackListener.start(
            queue: .main, timeout: 60,
            sleep: { rec.sleeps.append($0) },
            bind: { _ in
                rec.attempts += 1
                if rec.attempts < 3 { throw LoopbackListener.LoopbackError.bindRefusedForNow("busy") }
                return (spare, 4242)
            },
            onConnection: { _ in })
        #expect(port == 4242)
        #expect(rec.attempts == 3)
        #expect(rec.sleeps == [LoopbackListener.bindRetryDelay, LoopbackListener.bindRetryDelay])
    }

    // A permanent failure is reported at once, with no pause and no second attempt: retrying it
    // spends the person's whole wait to reach the same answer (L110).
    @Test func aPermanentFailureIsNotRetried() async {
        let rec = Recorder()
        await #expect(throws: LoopbackListener.LoopbackError.self) {
            _ = try await LoopbackListener.start(
                queue: .main, timeout: 60,
                sleep: { rec.sleeps.append($0) },
                bind: { _ in rec.attempts += 1; throw LoopbackListener.LoopbackError.failed("no permission") },
                onConnection: { _ in })
        }
        #expect(rec.attempts == 1)
        #expect(rec.sleeps.isEmpty)
    }

    // Every attempt spent is its own answer, naming the tries, never a generic failure.
    @Test func runningOutOfAttemptsSaysSo() async {
        let rec = Recorder()
        do {
            _ = try await LoopbackListener.start(
                queue: .main, timeout: 60,
                sleep: { rec.sleeps.append($0) },
                bind: { _ in rec.attempts += 1; throw LoopbackListener.LoopbackError.bindRefusedForNow("busy") },
                onConnection: { _ in })
            Issue.record("expected a refusal")
        } catch let error as LoopbackListener.LoopbackError {
            guard case .bindRefusedForNow = error else { Issue.record("wrong case: \(error)"); return }
        } catch { Issue.record("wrong error: \(error)") }
        #expect(rec.attempts == LoopbackListener.bindAttempts)
        #expect(rec.sleeps.count == LoopbackListener.bindAttempts - 1)
    }
}
