import Foundation
import Network
import Testing
// PLAIN IMPORT, DELIBERATELY, the same reason `PublicDecodeHealthSurfaceTests`
// gives (backstage#12): every other listener suite uses `@testable`, which sees
// internal declarations, so nothing asserted under one can show that a CONSUMER
// could reach the same name. Import visibility is per file, so this file
// compiles against the public surface alone and stops building the moment any
// of these stops being public.
//
// It exists because the listener was internal, which is why Downbeat could not
// use it and carried its own copy instead (backstage#60, downbeat#505).
import BackstageGoogle

struct PublicLoopbackSurfaceTests {

    /// A consumer outside the package can start a listener and read what came
    /// back. Nothing here asserts behaviour; the point is that it COMPILES.
    @Test func aconsumerCanStartAListenerAndReadThePort() async throws {
        let (listener, port) = try await LoopbackListener.start(
            queue: .main,
            timeout: 5,
            port: nil,
            onConnection: { _ in }
        )
        defer { listener.cancel() }
        #expect(port != 0)
    }

    /// And name the port it wants, which is the whole of backstage#60: a consumer
    /// that builds its redirect URI BEFORE binding cannot use an assigned one.
    ///
    /// Whether the bind SUCCEEDS on a port just released is `LoopbackFixedPortTests`'
    /// subject; this file only has to show a consumer can ask.
    @Test func aconsumerCanAskForAParticularPort() async throws {
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

    /// The failure type is public too, and reachable by case. A consumer that can
    /// hold an error it cannot examine has to read the rendered message instead,
    /// which is the thing `bindRefusedForNow` was made a case to avoid (L35).
    @Test func aconsumerCanTellTheFailuresApart() {
        let errors: [LoopbackListener.LoopbackError] = [
            .noPort, .failed("x"), .timedOut, .bindRefusedForNow("y"),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
        if case .bindRefusedForNow = errors[3] {} else {
            Issue.record("a consumer cannot match bindRefusedForNow by case")
        }
    }

    /// The tuned numbers are readable, so a consumer wording a status line around
    /// them quotes the value the package judges by rather than writing its own
    /// beside it (L41, and the README's own rule about the decode threshold).
    @Test func thetunedNumbersAreReadable() {
        #expect(LoopbackListener.defaultTimeout > 0)
        #expect(LoopbackListener.bindAttempts >= 1)
        #expect(LoopbackListener.bindRetryDelay >= 0)
    }
}
