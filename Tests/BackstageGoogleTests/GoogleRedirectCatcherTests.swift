import Foundation
import Network
import Testing
@testable import BackstageGoogle

// The redirect catch, shared rather than kept inside the Gmail manager (backstage#61).
//
// Four behaviours used to live in `GmailAuthManager`: waiting for Google's redirect, reading the
// request line, answering the browser, and matching the state before handing back the code. A second
// consumer of the same catch could reach none of them, so Downbeat carried its own copy of all four
// and the two spellings had already drifted apart (L263, L613).
//
// The pure parts are asserted WITHOUT binding anything, because the parse and the three pages are
// what a person reads and they must not need a socket to be checked. The live parts bind
// 127.0.0.1, which touches nothing outside this machine, and each one waits on the condition it is
// about rather than on a duration (L290).
@MainActor
struct GoogleRedirectCatcherTests {

    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    private let queue = DispatchQueue(label: "backstage.redirect-catch.tests")

    private func catcher(productName: String = "Ovation",
                         expectedState: String = "the-state",
                         sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil)
    -> GoogleRedirectCatcher {
        GoogleRedirectCatcher(productName: productName, expectedState: expectedState,
                              queue: queue, sleep: sleep)
    }

    /// Plays the browser: visits the loopback URL and records the page it was served.
    private func visit(_ url: String, recordingInto page: Box<String?>) {
        Task.detached {
            let got = try? await URLSession(configuration: .ephemeral).data(from: URL(string: url)!)
            page.value = got.map { String(decoding: $0.0, as: UTF8.self) } ?? ""
        }
    }

    /// Waits for a condition rather than for a duration, with a ceiling far above what the thing
    /// being waited for takes, so a saturated machine does not decide the verdict (L224, L290).
    private func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<1_000 where !condition() { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(condition(), "never became true: \(what)")
    }

    // MARK: - reading the request line

    // A real request line, which is what Google's redirect arrives as.
    @Test func thePathIsReadOffTheRequestLine() {
        let request = "GET /?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        #expect(GoogleRedirectCatcher.requestedPath(from: request) == "/?code=abc&state=xyz")
    }

    // NIL rather than an empty path, because an empty path parses to a redirect carrying no code,
    // and that is a different thing to tell somebody than "this was not a request at all" (L11).
    // It is also what the Gmail flow's own reachability probe looks like: it connects and sends
    // nothing, so the request is empty and must not resolve anybody's wait.
    @Test func nothingIsNotARequestLine() {
        #expect(GoogleRedirectCatcher.requestedPath(from: "") == nil)
    }

    // Google redirects the browser with GET. Anything else reaching this port is not the redirect.
    @Test func onlyAGetIsARedirect() {
        #expect(GoogleRedirectCatcher.requestedPath(from: "POST /?code=abc HTTP/1.1\r\n\r\n") == nil)
    }

    // MARK: - reading the query

    @Test func theCodeTheErrorAndTheStateAreAllReadFromTheQuery() {
        let answer = GoogleRedirectCatcher.answer(fromRedirectPath: "/?code=abc&error=nope&state=xyz")
        #expect(answer == GoogleRedirectCatcher.Answer(code: "abc", error: "nope", state: "xyz"))
    }

    @Test func aRedirectCarryingNothingParsesToAnEmptyAnswer() {
        #expect(GoogleRedirectCatcher.answer(fromRedirectPath: "/")
                == GoogleRedirectCatcher.Answer(code: nil, error: nil, state: nil))
    }

    // MARK: - which of the three things happened

    @Test func aCodeMeansGooglesAnswerArrived() {
        #expect(GoogleRedirectCatcher.outcome(for: .init(code: "abc", error: nil, state: "xyz")) == .received)
    }

    @Test func anErrorMeansGoogleRefused() {
        #expect(GoogleRedirectCatcher.outcome(for: .init(code: nil, error: "access_denied", state: "xyz"))
                == .refused("access_denied"))
    }

    @Test func neitherMeansThereIsNothingToConnectWith() {
        #expect(GoogleRedirectCatcher.outcome(for: .init(code: nil, error: nil, state: "xyz")) == .noAnswer)
    }

    // MARK: - what the browser tab is left showing

    // backstage#25 settled this and it is the base the per outcome branch was added to: the page is
    // written the moment the redirect lands, BEFORE the exchange and before the save, either of
    // which can still fail. So it may say Google's answer arrived and no more (L12, L11).
    @Test func theReceivedPageNeverClaimsAConnection() {
        let body = GoogleRedirectCatcher.pageBody(productName: "Ovation", for: .received).lowercased()
        #expect(!body.contains("connected"), "the tab claimed a connection it has not made: \(body)")
        #expect(body.contains("ovation"), "the tab does not say which app to go back to")
    }

    // What Downbeat's copy had and this did not: somebody who was refused reads why in the tab they
    // are already looking at, rather than being sent back to find out.
    @Test func theRefusalPageQuotesWhatGoogleSaid() {
        let body = GoogleRedirectCatcher.pageBody(productName: "Ovation", for: .refused("access_denied"))
        #expect(body.contains("access_denied"), "the tab does not say why: \(body)")
    }

    @Test func aRedirectWithNoAnswerSaysThatRatherThanNothing() {
        let body = GoogleRedirectCatcher.pageBody(productName: "Ovation", for: .noAnswer).lowercased()
        #expect(body.contains("without an answer"), "the tab does not say what happened: \(body)")
    }

    // ANYTHING CAN REACH THIS PORT, so Google's reason is not trusted content: a page opened at
    // 127.0.0.1 with `?error=<script>` is written by whoever opened it. The reason is quoted, so it
    // is escaped, or the page runs what it was handed.
    @Test func whatGoogleSaidIsEscapedRatherThanRendered() {
        let body = GoogleRedirectCatcher.pageBody(productName: "Ovation",
                                                  for: .refused("<script>alert(1)</script>"))
        #expect(!body.contains("<script"), "the reason was rendered as markup: \(body)")
        #expect(body.contains("&lt;script&gt;"), "the reason was dropped rather than escaped: \(body)")
    }

    // The product name comes from a consumer, and the same rule applies to it for the same reason:
    // it lands in a title and a sentence, and one apostrophe in it would otherwise break the page.
    @Test func theProductNameIsEscapedIntoThePage() {
        let body = GoogleRedirectCatcher.pageBody(productName: "A <b>bold</b> app", for: .received)
        #expect(!body.contains("<b>"), "the product name was rendered as markup: \(body)")
        #expect(body.contains("&lt;b&gt;bold&lt;/b&gt;"))
    }

    // A Content-Length that disagrees with the body is a tab that sits loading for ever, which reads
    // as the sign in having failed. Measured off the body rather than restated.
    @Test func theReplyDeclaresTheLengthOfTheBodyItCarries() throws {
        let body = GoogleRedirectCatcher.pageBody(productName: "Ovation", for: .received)
        let reply = String(decoding: GoogleRedirectCatcher.reply(productName: "Ovation", for: .received),
                           as: UTF8.self)
        #expect(reply.contains("Content-Length: \(body.utf8.count)\r\n"), "wrong length in: \(reply)")
        #expect(reply.hasSuffix(body))
        #expect(reply.contains("Connection: close"))
    }

    // MARK: - the port a consumer asks for

    // Read off what the catcher ASKED its bind for, so this says the port was requested rather than
    // that the OS happened to assign it (L70).
    @Test func thePortAConsumerNamesIsWhatGetsBound() async throws {
        let asked = Box<UInt16?>(nil)
        let spare = try NWListener(using: .tcp)
        defer { spare.cancel() }
        let subject = GoogleRedirectCatcher(
            productName: "Downbeat", expectedState: "s", port: 8765, queue: queue,
            bind: { port, _, _ in asked.value = port; return (spare, port ?? 0) })
        _ = try await subject.start()
        #expect(asked.value == 8765)
    }

    // Nil is the OS assigning one, which is what a consumer building its redirect URI from the port
    // that came back needs, and it is the default so no existing call site changes.
    @Test func namingNoPortLeavesTheChoiceToTheOS() async throws {
        let asked = Box<UInt16?>(0)
        let spare = try NWListener(using: .tcp)
        defer { spare.cancel() }
        let subject = GoogleRedirectCatcher(
            productName: "Ovation", expectedState: "s", queue: queue,
            bind: { port, _, _ in asked.value = port; return (spare, 1) })
        _ = try await subject.start()
        #expect(asked.value == nil)
    }

    // A catch takes ONE port and answers ONCE. A second start used to replace the listener without
    // cancelling the first, so the abandoned one held its port for the life of the process, which is
    // the exact condition that makes the next sign in bind somewhere Google is not redirecting to.
    @Test func aSecondStartIsRefusedRatherThanAbandoningTheFirstPort() async throws {
        let subject = catcher()
        let port = try await subject.start()

        await #expect(throws: GoogleRedirectCatcher.Failure.alreadyStarted) { _ = try await subject.start() }
        #expect(subject.boundPort == port, "the catch moved to another port and left the first bound")
    }

    // MARK: - the whole catch, over a real loopback port

    @Test func aRedirectCarryingTheCodeHandsItBack() async throws {
        let subject = catcher()
        let port = try await subject.start()
        let page = Box<String?>(nil)
        visit("http://127.0.0.1:\(port)/?code=the-code&state=the-state", recordingInto: page)

        let code = try await subject.awaitCode(timeout: 30)
        #expect(code == "the-code")
        try await until("the tab was answered") { page.value != nil }
        #expect(try #require(page.value).lowercased().contains("reached"))
    }

    // The state is the only thing standing between this port and a code somebody else put there, so
    // a mismatch is its own refusal rather than a missing code.
    @Test func aRedirectWhoseStateDoesNotMatchIsRefused() async throws {
        let subject = catcher()
        let port = try await subject.start()
        let page = Box<String?>(nil)
        visit("http://127.0.0.1:\(port)/?code=the-code&state=forged", recordingInto: page)

        await #expect(throws: GoogleRedirectCatcher.Failure.stateMismatch) {
            _ = try await subject.awaitCode(timeout: 30)
        }
        try await until("the tab was answered") { page.value != nil }
        #expect(!(try #require(page.value).lowercased().contains("connected")))
    }

    // Google refusing is a DIFFERENT outcome from a redirect with no code, and it carries the reason
    // Google gave, which is the whole point of separating them.
    @Test func aRefusalFromGoogleComesBackWithItsReason() async throws {
        let subject = catcher()
        let port = try await subject.start()
        let page = Box<String?>(nil)
        visit("http://127.0.0.1:\(port)/?error=access_denied&state=the-state", recordingInto: page)

        await #expect(throws: GoogleRedirectCatcher.Failure.refusedByGoogle("access_denied")) {
            _ = try await subject.awaitCode(timeout: 30)
        }
        try await until("the tab was answered") { page.value != nil }
        #expect(try #require(page.value).contains("access_denied"))
    }

    // A redirect carrying a matching state and no code at all is neither a refusal nor a success.
    @Test func aRedirectWithAMatchingStateAndNoCodeIsItsOwnFailure() async throws {
        let subject = catcher()
        let port = try await subject.start()
        visit("http://127.0.0.1:\(port)/?state=the-state", recordingInto: Box<String?>(nil))

        await #expect(throws: GoogleRedirectCatcher.Failure.noCode) {
            _ = try await subject.awaitCode(timeout: 30)
        }
    }

    // THE HANG THIS DESIGN EXISTS TO AVOID. The redirect can land between the bind returning and the
    // wait starting, and a catcher that settled with nothing waiting would leave the next wait
    // hanging for ever, which cannot be told from slowness and holds the port while it does (L110).
    @Test func aRedirectThatLandsBeforeAnybodyWaitsIsStillHandedOver() async throws {
        let subject = catcher()
        let port = try await subject.start()
        visit("http://127.0.0.1:\(port)/?code=early&state=the-state", recordingInto: Box<String?>(nil))
        try await until("the catcher settled") { subject.hasSettled }

        // Waited on from a task rather than inline, because the failure this guards against is a
        // wait that never ends. Awaiting it here would make a broken catcher HANG the suite instead
        // of failing it, and a red that never arrives is the thing being tested, twice over.
        let handed = Box<String?>(nil)
        Task { handed.value = try? await subject.awaitCode(timeout: 30) }
        try await until("the wait was answered") { handed.value != nil }
        #expect(handed.value == "early")
    }

    // A browser asks for a favicon, and a port scan asks for whatever it likes. Neither is Google's
    // redirect, and resolving the wait from one would fail a healthy sign in with a bogus mismatch.
    @Test func aRequestThatIsNotTheRedirectDoesNotSettleTheWait() async throws {
        let subject = catcher()
        let port = try await subject.start()
        let favicon = Box<String?>(nil)
        visit("http://127.0.0.1:\(port)/favicon.ico", recordingInto: favicon)
        try await until("the favicon was answered") { favicon.value != nil }
        #expect(!subject.hasSettled, "a favicon request settled the sign in")

        visit("http://127.0.0.1:\(port)/?code=the-code&state=the-state", recordingInto: Box<String?>(nil))
        #expect(try await subject.awaitCode(timeout: 30) == "the-code")
    }

    // The Gmail flow probes its own listener before opening the browser (origin #1163). That probe
    // connects and sends nothing, so it must not settle anything either. Driven through the real
    // probe rather than an imitation of it, because the composition is the claim.
    @Test func theReachabilityProbeDoesNotSettleTheWait() async throws {
        let subject = catcher()
        let port = try await subject.start()
        #expect(await subject.reachable())
        #expect(!subject.hasSettled, "the reachability probe settled the sign in")
    }

    // MARK: - whether the port is actually accepting

    // A listener can report itself ready and hold no socket, which is what leaves a person looking
    // at a browser tab that cannot connect. Asking the catch about its OWN port is the check, and
    // it is the catch's to answer because the port is already there.
    @Test func aLiveCatchSaysItsPortIsAccepting() async throws {
        let subject = catcher()
        _ = try await subject.start()
        #expect(await subject.reachable())
    }

    // And it says no once the port has gone, which is the half that has to be true for the check to
    // be worth making at all.
    //
    // WHAT THIS MEASURES, exactly: the ANSWER, which arrives on the deadline rather than from a
    // refused connection. A connection to a closed local port reports itself waiting rather than
    // failed, so the no comes from the timeout, and this test stays green if the failed branch is
    // inverted. That is the shipped behaviour and the reason the check is documented as failing in
    // about two seconds rather than at once; it is written down here so nobody reads this as
    // covering that branch (L400).
    @Test func aStoppedCatchSaysItsPortIsNotAccepting() async throws {
        let subject = catcher()
        _ = try await subject.start()
        subject.stop()

        var stillAccepting = true
        for _ in 0..<200 where stillAccepting {
            stillAccepting = await subject.reachable()
            if stillAccepting { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        #expect(!stillAccepting)
    }

    // NOT REACHABLE rather than a crash or a claim: a catch that never took a port has no port to
    // answer about, and the answer a caller acts on must be the safe one.
    @Test func aCatchThatNeverTookAPortIsNotReachable() async throws {
        #expect(!(await catcher().reachable()))
    }

    // MARK: - giving up

    // backstage#13: every wait runs on the injected clock, so a redirect that never arrives fails at
    // once here rather than after the real ninety seconds.
    @Test func aRedirectThatNeverArrivesGivesUpOnTheInjectedClock() async throws {
        // The give up window returns at once; every other wait parks, so the only thing that can
        // end this test is the give up.
        let subject = catcher(sleep: { seconds in
            if seconds >= 60 { return }
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        })
        _ = try await subject.start()
        await #expect(throws: GoogleRedirectCatcher.Failure.timedOut) {
            _ = try await subject.awaitCode(timeout: 90)
        }
    }

    struct TheListenerDied: Error, Equatable {}

    // A consumer watching the listener from outside (the Gmail flow re-probes it mid wait) has to be
    // able to end the wait with ITS OWN reason, or the only way to report a dead listener is to wait
    // out the give up window it was meant to cut short.
    @Test func aConsumerCanEndTheWaitWithItsOwnReason() async throws {
        let subject = catcher()
        _ = try await subject.start()
        Task { @MainActor in subject.abandon(reason: TheListenerDied()) }
        await #expect(throws: TheListenerDied()) { _ = try await subject.awaitCode(timeout: 30) }
    }

    // A second wait on one catcher is refused rather than left hanging: one catch, one answer.
    @Test func aSecondWaitIsRefusedRatherThanLeftHanging() async throws {
        let subject = catcher()
        _ = try await subject.start()
        let first = Task { try await subject.awaitCode(timeout: 30) }
        try await until("the first wait is in place") { subject.isWaiting }

        await #expect(throws: GoogleRedirectCatcher.Failure.alreadyWaiting) {
            _ = try await subject.awaitCode(timeout: 30)
        }
        subject.abandon(reason: TheListenerDied())
        _ = try? await first.value
    }

    // MARK: - letting the port go

    // It answers once and then stops. A listener left running holds the port for the life of the
    // process, and the next attempt finds it taken and is redirected somewhere nothing is listening.
    @Test func thePortIsReleasedOnceTheCodeIsHandedBack() async throws {
        let subject = catcher()
        let port = try await subject.start()
        visit("http://127.0.0.1:\(port)/?code=the-code&state=the-state", recordingInto: Box<String?>(nil))
        _ = try await subject.awaitCode(timeout: 30)

        var stillAccepting = true
        for _ in 0..<200 where stillAccepting {
            stillAccepting = await GoogleRedirectCatcher.isReachable(
                port: port, queue: queue,
                sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
            if stillAccepting { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        #expect(!stillAccepting, "the listener is still holding 127.0.0.1:\(port)")
    }
}
