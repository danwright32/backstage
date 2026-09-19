// Ported-From: danwright32/overture mac/Overture/Integration/GmailNetworking.swift @ 0bb3869c8f71777d08712e9fa146fd07c6da699f
//
// Ported on 2026-09-19 by backstage#2. Do not edit this copy to fix a fault that is also in
// the origin: fix it there and re-port (L263).
//
// Taken whole, and then EXTENDED with the test refusal (backstage#5), which the origin never had.
// Internal: no consumer needs to name it.
import Foundation

// #468 (SUP-004): a single, bounded URLSession every Gmail call routes through by default. The
// plain URLSession.shared this replaced has a 7-day resource timeout, so a stalled call (token
// refresh, send, reply check) could hang for days with no recovery short of an app restart. Every
// call site here still injects its own fetch closure for tests, so this only changes what a real
// production call actually waits on.
enum GmailNetworking {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    // backstage#5: A TEST RUN CAN NEVER REACH GOOGLE. The refusal is here, at the one place a live call
    // is made, and not in any consumer, because a refusal only one consumer carries hands every other
    // consumer an unrefusing client the day it migrates (L196, L378). Zero of the origin's fifteen
    // Gmail files carried one.
    public struct RefusedUnderTests: LocalizedError, Equatable {
        public var errorDescription: String? {
            "A live Gmail call was refused because this process is a test run. Inject a fetch instead."
        }
    }

    // Is this process a test run? SEVERAL independent signs, any one of which is enough, because the
    // first version trusted one and it was wrong.
    //
    // MEASURED 2026-09-19, not assumed. The first version asked only whether a `.xctest` bundle was
    // loaded. Under `swift test` the runner is `swiftpm-testing-helper`, which loads no test bundle into
    // `Bundle.allBundles` and sets no test environment variable, so the check said "not a test run",
    // the refusal was inert, and a test built on the live default sent a real request to Gmail with a
    // placeholder token and got a 401 back. TestRefusalTests caught it because it asserts the detection
    // itself in the real harness rather than trusting it (L1, L322).
    //
    // What that measurement found, and what each sign below covers:
    //   the XCTest framework is LOADED   under swift test (XCTestCase resolves), under xcodebuild and
    //                                    Xcode, and in a hosted app test; a shipped app never loads it
    //   XCTestConfigurationFilePath      set by xcodebuild and Xcode for hosted and logic tests
    //   the runner's own process name    swiftpm-testing-helper, or xctest
    //   a loaded .xctest bundle          the hosted case, where the bundle is injected into the app
    static func isTestRun() -> Bool {
        let process = ProcessInfo.processInfo
        if NSClassFromString("XCTestCase") != nil { return true }
        if process.environment["XCTestConfigurationFilePath"] != nil { return true }
        if ["swiftpm-testing-helper", "xctest"].contains(process.processName) { return true }
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }

    // The decision alone, so both outcomes can be asserted without touching the network (L159).
    static func refusal(underTests: Bool) -> RefusedUnderTests? {
        underTests ? RefusedUnderTests() : nil
    }

    // The live fetch every default in this package routes through.
    static func live(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let refused = refusal(underTests: isTestRun()) { throw refused }
        return try await session.data(for: request)
    }
}
