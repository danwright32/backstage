import Foundation
import Network
import Testing
@testable import BackstageGoogle

// What it means for a consumer to NAME the port (backstage#60).
//
// Gmail lets the OS assign one and builds its redirect URI from what came back.
// Downbeat registered a fixed redirect URI and builds it BEFORE binding, so it
// has to ask for that port. Both are right, which is why the port is a
// parameter rather than a change of mind.
//
// THE DESIGN QUESTION THIS FILE SETTLED. The retry already here was calibrated
// for an assigned port, where EADDRINUSE means the OS picked something busy and
// picking again is the answer. On a named port it looked like the opposite:
// another process holds that port and will still hold it in 100ms, so retrying
// spends the person's wait to reach the same refusal (L110). That was
// implemented, and the first test written against it failed: binding an
// assigned port, cancelling it and asking for the same port back returns
// EADDRINUSE, because `cancel()` returns before the socket finishes winding
// down. A named port has two causes for that code, they cannot be told apart
// from the code, and the transient one is the common one. It is what happens
// when somebody presses Connect, closes the window and presses Connect again.
//
// So the classification is unchanged and this file records why, because the
// argument for changing it is the one that suggests itself (L497, L542).
struct LoopbackFixedPortTests {

    // MARK: the endpoint the parameters carry

    // Read off the parameters rather than by binding, so this says what was
    // ASKED FOR. A test that binds and reads the result back cannot tell a
    // request for a port from the OS happening to assign that port.
    @Test func afixedPortIsPinnedOnTheLoopbackEndpoint() throws {
        let params = LoopbackListener.parameters(port: 8765)
        guard case .hostPort(let host, let port) = params.requiredLocalEndpoint else {
            Issue.record("no required local endpoint, so the bind is not pinned at all")
            return
        }
        #expect(port.rawValue == 8765)
        #expect("\(host)" == "127.0.0.1")
    }

    // The default is unchanged, which is the half that keeps Gmail working.
    @Test func noPortStillMeansTheOSPicksOne() throws {
        let params = LoopbackListener.parameters(port: nil)
        guard case .hostPort(let host, let port) = params.requiredLocalEndpoint else {
            Issue.record("no required local endpoint, so IPv4 is no longer pinned")
            return
        }
        #expect(port == .any)
        #expect("\(host)" == "127.0.0.1")
    }

    // IPv4 pinning is the fix this package has and the copies of it do not
    // (#51), so it has to survive a port being named. Without it `NWListener`
    // can bind IPv6 and Google's redirect to 127.0.0.1 never arrives.
    @Test func ipv4IsPinnedWhicheverPortIsAskedFor() {
        for wanted in [nil, UInt16(8765), UInt16(1)] {
            let params = LoopbackListener.parameters(port: wanted)
            guard case .hostPort(let host, _) = params.requiredLocalEndpoint else {
                Issue.record("no required local endpoint for port \(String(describing: wanted))")
                continue
            }
            #expect("\(host)" == "127.0.0.1")
        }
        #expect(LoopbackListener.parameters(port: nil).allowLocalEndpointReuse)
    }

    // MARK: a real bind on a named port

    // The case that settled the design question above, kept because it is the
    // evidence rather than a demonstration: a port released a moment ago comes
    // back EADDRINUSE on the first attempt and binds on a later one. It passes
    // BECAUSE the retry treats that code as worth another try, so if somebody
    // makes EADDRINUSE permanent on a named port again, this goes red.
    //
    // It waits on the condition rather than on a duration: the package's own
    // three attempts are the wait, and the assertion is about what came back
    // (L290).
    @Test func areleasedPortCanBeAskedForAgainAndTheRetryIsWhatMakesItWork() async throws {
        let (first, wanted) = try await LoopbackListener.start(
            queue: .main, timeout: 10, port: nil, onConnection: { _ in }
        )
        first.cancel()

        let (listener, got) = try await LoopbackListener.start(
            queue: .main, timeout: 10, port: wanted, onConnection: { _ in }
        )
        defer { listener.cancel() }
        #expect(got == wanted, "asked for \(wanted) and was given \(got)")
    }

    // MARK: the loop, driven through its seam

    final class Recorder: @unchecked Sendable {
        var sleeps: [TimeInterval] = []
        var attempts = 0
    }

    // Naming a port did not quietly turn the retry off. Driven through the bind
    // seam so the schedule is read from the delays it ASKED FOR rather than
    // lived through (L524).
    @Test func atransientRefusalIsStillRetriedOnAFixedPort() async throws {
        let rec = Recorder()
        let spare = try NWListener(using: .tcp)
        defer { spare.cancel() }
        let (_, port) = try await LoopbackListener.start(
            queue: .main, timeout: 60, port: 8765,
            sleep: { rec.sleeps.append($0) },
            bind: { _ in
                rec.attempts += 1
                if rec.attempts < 2 {
                    throw LoopbackListener.LoopbackError.bindRefusedForNow("not right now")
                }
                return (spare, 8765)
            },
            onConnection: { _ in })
        #expect(port == 8765)
        #expect(rec.attempts == 2)
        #expect(rec.sleeps == [LoopbackListener.bindRetryDelay])
    }

    // And a permanent failure on a named port is still answered once, so the
    // case above is not satisfied by a loop that retries everything.
    @Test func apermanentFailureOnAFixedPortIsNotRetried() async {
        let rec = Recorder()
        await #expect(throws: LoopbackListener.LoopbackError.self) {
            _ = try await LoopbackListener.start(
                queue: .main, timeout: 60, port: 8765,
                sleep: { rec.sleeps.append($0) },
                bind: { _ in
                    rec.attempts += 1
                    throw LoopbackListener.LoopbackError.failed("no permission")
                },
                onConnection: { _ in })
        }
        #expect(rec.attempts == 1)
        #expect(rec.sleeps.isEmpty)
    }
}
