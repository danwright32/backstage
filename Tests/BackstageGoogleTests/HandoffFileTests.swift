import Foundation
import Testing
@testable import BackstageGoogle

// Reading a file something else wrote, keeping "could not read it" apart from "there is nothing".
// backstage#2. Every test gets its own register and its own directory, so no test can see what
// another recorded (L2).
struct HandoffFileTests {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backstage-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct Payload: Codable, Equatable { var name: String }

    @Test func anAbsentFileIsAbsentAndLeavesNoRecord() throws {
        let recorder = HandoffReadFailures()
        let url = try scratch().appendingPathComponent("nothing-here.json")
        let read = HandoffFile.read(at: url, recorder: recorder) { try JSONDecoder().decode(Payload.self, from: $0) }
        #expect(read == .absent)
        #expect(recorder.current().isEmpty)
    }

    // THE WHOLE POINT. A file that is there and cannot be decoded must never come back as absent,
    // and the reason must name the FIELD, because that one fact is what makes it fixable.
    @Test func anUndecodableFileIsUnreadableNamesTheFieldAndIsRecorded() throws {
        let recorder = HandoffReadFailures()
        let url = try scratch().appendingPathComponent("tokens.json")
        try Data(#"{"other":"x"}"#.utf8).write(to: url)
        let read = HandoffFile.read(at: url, recorder: recorder) { try JSONDecoder().decode(Payload.self, from: $0) }

        guard case .unreadable(let reason) = read else {
            Issue.record("expected unreadable, got \(read)"); return
        }
        #expect(reason.contains("name"), "the reason must name the missing field: \(reason)")
        #expect(recorder.current().map(\.file) == ["tokens.json"])
    }

    // Something that exists but cannot be OPENED at all, here a directory where a file is expected.
    @Test func somethingThatExistsButCannotBeOpenedIsUnreadableNotAbsent() throws {
        let recorder = HandoffReadFailures()
        let url = try scratch().appendingPathComponent("a-directory")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let read = HandoffFile.data(at: url, recorder: recorder)
        if case .unreadable = read {} else { Issue.record("expected unreadable, got \(read)") }
    }

    // A record ends when the file becomes readable, and only then (L160).
    @Test func aGoodReadClearsTheEarlierFailure() throws {
        let recorder = HandoffReadFailures()
        let url = try scratch().appendingPathComponent("tokens.json")
        try Data("not json".utf8).write(to: url)
        _ = HandoffFile.read(at: url, recorder: recorder) { try JSONDecoder().decode(Payload.self, from: $0) }
        #expect(recorder.current().count == 1)

        try Data(#"{"name":"ok"}"#.utf8).write(to: url)
        let read = HandoffFile.read(at: url, recorder: recorder) { try JSONDecoder().decode(Payload.self, from: $0) }
        #expect(read == .read(Payload(name: "ok")))
        #expect(recorder.current().isEmpty)
    }

    // A repeat is counted, not duplicated: a poll that fails every second must not become a list
    // of two hundred identical lines (L36).
    @Test func aRepeatedFailureIsCountedNotDuplicated() throws {
        let recorder = HandoffReadFailures()
        let url = try scratch().appendingPathComponent("tokens.json")
        try Data("not json".utf8).write(to: url)
        for _ in 0..<3 {
            _ = HandoffFile.read(at: url, recorder: recorder) { try JSONDecoder().decode(Payload.self, from: $0) }
        }
        #expect(recorder.current().map(\.count) == [3])
    }
}
