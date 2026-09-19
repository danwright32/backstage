import Foundation
import Testing
// PLAIN IMPORT, DELIBERATELY. Every other suite here uses `@testable`, which
// sees internal declarations too, so no assertion made under one can show that a
// consumer of this package could reach the same thing. Import visibility is per
// file, so this file compiles against the public surface alone: if any of the
// names below stopped being public, this file would not build (backstage#12).
import BackstageGoogle

struct PublicDecodeHealthSurfaceTests {

    // A CONSUMER READS THE TALLY WITHOUT NAMING ANYTHING INTERNAL. Each field is
    // touched, because a struct that is public while its properties are not is
    // a surface a consumer can hold and cannot read.
    @Test func aConsumerCanReadTheTallyAndEveryFieldOfIt() {
        let reading: [EndpointDecodeHealth] = ResponseDecodeHealth.shared.current()
        for endpoint in reading {
            _ = endpoint.endpoint
            _ = endpoint.attempts
            _ = endpoint.failures
            _ = endpoint.consecutiveFailures
            _ = endpoint.lastReason
            _ = endpoint.isFailing
        }
        _ = ResponseDecodeHealth.shared.failing()
    }

    // THE THRESHOLD IS PART OF THE SURFACE. A consumer deciding what to show
    // must read the same number the package judges by, rather than writing its
    // own three beside it (L41).
    //
    // Asserted as a VALUE, not merely as reachable: a consumer wording a status
    // line around it is making a claim about what the package does.
    @Test func theThresholdThePackageJudgesByIsReadable() {
        #expect(ResponseDecodeHealth.failingRun == 3)
    }
}
