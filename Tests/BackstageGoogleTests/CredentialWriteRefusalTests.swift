import Foundation
import Testing
@testable import BackstageGoogle

// A credential WRITE or DELETE is refused inside a test run unless it targets a
// throwaway path (backstage#44).
//
// backstage#5 put a refusal at the one place a live Gmail call is made, which
// covers the way IN. It did not cover the way OUT: `saveTokens` and
// `clearTokens` name a path directly and are reachable from `disconnect()`,
// `signalAuthExpired()`, `persistExchangedTokens` and `validAccessToken`. A seam
// that keeps a test off live data on the way in does not cover the way out, and
// the way out is the half that cannot be undone (L201, L5).
//
// THE DECISION IS ASSERTED SEPARATELY FROM THE ACT, so both outcomes are covered
// without either one writing to a real path (L159). The seam naming what counts
// as throwaway is what lets the refusing case be driven at all: a test cannot
// prove the refusal by pointing at Dan's real credentials.
struct CredentialWriteRefusalTests {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backstage-44-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // --- the decision itself ---

    @Test func outsideATestRunNothingIsRefused() throws {
        let live = URL(fileURLWithPath: "/Users/someone/Library/Application Support/App/tokens.json")
        #expect(GmailCredentials.writeRefusal(at: live, underTests: false,
                                              throwaway: try scratch()) == nil)
    }

    @Test func insideATestRunAThrowawayPathIsAllowed() throws {
        let throwaway = try scratch()
        let target = throwaway.appendingPathComponent("tokens.json")
        #expect(GmailCredentials.writeRefusal(at: target, underTests: true,
                                              throwaway: throwaway) == nil)
    }

    // THE CASE THE ISSUE IS ABOUT: a test pointed at a real credentials directory.
    @Test func insideATestRunAPathOutsideTheThrowawayIsRefused() throws {
        let live = URL(fileURLWithPath: "/Users/someone/Library/Application Support/App/tokens.json")
        let refusal = GmailCredentials.writeRefusal(at: live, underTests: true,
                                                    throwaway: try scratch())
        #expect(refusal != nil)
        #expect(refusal?.errorDescription?.isEmpty == false)
    }

    // CONTAINMENT IS BY PATH COMPONENT, NOT BY STRING PREFIX. A sibling whose
    // name merely begins with the throwaway directory's name is not inside it,
    // and a guard comparing strings would wave it through (L266).
    @Test func aSiblingThatMerelyStartsWithTheSameLettersIsRefused() throws {
        let throwaway = try scratch()
        let sibling = URL(fileURLWithPath: throwaway.path + "-elsewhere/tokens.json")
        #expect(GmailCredentials.writeRefusal(at: sibling, underTests: true,
                                              throwaway: throwaway) != nil)
    }

    // --- the act, which must honour the decision ---

    @Test func aDeleteOutsideTheThrowawayIsRefusedAndTheFileSurvives() throws {
        let real = try scratch()
        let target = real.appendingPathComponent("tokens.json")
        #expect(try GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt"), to: target,
                                                throwaway: real))

        // Declaring a DIFFERENT throwaway root makes `real` a live path as far as
        // the refusal is concerned, which is how the refusing branch is driven
        // without any test pointing at a credentials directory somebody owns.
        let elsewhere = try scratch()
        #expect(throws: GmailCredentials.CredentialWriteRefused.self) {
            try GmailCredentials.clearTokens(at: target, throwaway: elsewhere)
        }
        #expect(FileManager.default.fileExists(atPath: target.path),
                "a refused delete must leave the credential where it was")
    }

    @Test func aWriteOutsideTheThrowawayIsRefusedAndNothingIsCreated() throws {
        let real = try scratch()
        let elsewhere = try scratch()
        let target = real.appendingPathComponent("tokens.json")
        #expect(throws: GmailCredentials.CredentialWriteRefused.self) {
            _ = try GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt"), to: target,
                                                throwaway: elsewhere)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    // WHAT IT MUST PRESERVE (L104). The ordinary case still works, or the
    // refusal would simply be the feature switched off.
    @Test func aThrowawayWriteAndDeleteStillWork() throws {
        let dir = try scratch()
        let target = dir.appendingPathComponent("tokens.json")
        #expect(try GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt"), to: target,
                                                throwaway: dir))
        #expect(GmailCredentials.loadTokens(from: target)?.refreshToken == "rt")
        try GmailCredentials.clearTokens(at: target, throwaway: dir)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    // AND THE MANAGER'S OWN DISCONNECT HONOURS IT, which is the path the issue
    // names: a consumer's test reaching disconnect() on a manager pointed at a
    // real credentials directory.
    @Test @MainActor func disconnectIsRefusedWhenItWouldDeleteALivePath() throws {
        let real = try scratch()
        let manager = try GmailAuthManager(credentialsDirectory: real,
                                           scopes: ["https://www.googleapis.com/auth/gmail.send"],
                                           productName: "Ovation")
        let target = GmailCredentials.tokenURL(in: real)
        #expect(try GmailCredentials.saveTokens(StoredTokens(refreshToken: "rt"), to: target,
                                                throwaway: real))

        manager.throwawayRoot = try scratch()
        #expect(throws: GmailCredentials.CredentialWriteRefused.self) {
            try manager.disconnect()
        }
        #expect(FileManager.default.fileExists(atPath: target.path))
    }
}
