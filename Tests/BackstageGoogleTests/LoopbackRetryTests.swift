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

    // The READINESS timeout runs on the injected sleep too, not only the retry pause, so no wait in
    // the listener is on a clock a test cannot control (backstage#13). Asserted from what the
    // listener ASKED the clock for, on a real bind. The fake parks until cancelled, the way the real
    // sleep does, because the listener cancels that wait the moment it is ready and a fake that
    // returned at once would tear a healthy listener down.
    @Test func theReadinessTimeoutIsAskedOfTheInjectedClock() async throws {
        let rec = Recorder()
        let (listener, port) = try await LoopbackListener.start(
            queue: DispatchQueue(label: "backstage.retry.readiness"), timeout: 45,
            sleep: { seconds in
                rec.sleeps.append(seconds)
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
            },
            onConnection: { $0.cancel() })
        defer { listener.cancel() }
        #expect(port != 0)
        // The timeout task starts alongside the bind, so wait on the CONDITION, bounded, rather than
        // on a fixed delay (L290).
        for _ in 0..<500 where rec.sleeps.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(rec.sleeps.count == 1)
        #expect((rec.sleeps.first ?? 0) > 0 && (rec.sleeps.first ?? 0) <= 45,
                "the readiness wait is the remaining budget, asked of the injected clock")
    }
}
