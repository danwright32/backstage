// Ported-From: danwright32/overture mac/Overture/Domain/HandoffFile.swift @ 0bb3869c8f71777d08712e9fa146fd07c6da699f
//
// Ported on 2026-09-19 by backstage#2. Do not edit this copy to fix a fault that is also in
// the origin: fix it there and re-port (L263).
//
// TAKEN WHOLE AND UNCHANGED, because it carries a FIX rather than a convenience: an unreadable
// credentials file is not an absent one, and read as absent it says Gmail was never connected.
// Internal for now; which of its failures a consumer can see is backstage#12's decision.
import Foundation

// Reading a file something outside the app wrote, with "I could not read this" kept apart from "there
// was nothing to read" (#2879).
//
// Every handoff file in this repo crosses a language boundary, is written by a detached run or a
// launcher script, and is read through a decoder that can throw. Until #2873 every one of those reads
// discarded its error with a `try?`, so an unreadable file and an absent one were the same thing to
// every caller. That is what made a one-line decoding bug cost a day: the reply drafter's results file
// could not be decoded, the ingest returned as though there were nothing to ingest, and every AI reply
// draft Overture produced was dropped while the screen showed a spinner for it.
//
// An unreadable file is not an absent one (L105) and distinct causes need distinct messages (L11).
//
// The recording is done HERE rather than by each caller, and that is the design decision worth
// understanding. Several of these reads are deliberately best-effort and must go on behaving exactly as
// they do: a shortfall check with no record of what it asked for reports nothing rather than inventing a
// failure, and a progress file read once a second must never raise a warning per tick. Making each of
// those callers plumb a failure somewhere would have meant either changing behaviour that is correct, or
// (far more likely) leaving most of them silent, which is the defect being fixed rather than a fix.
// Recording at the read means every site gets a surface for free while keeping its own behaviour.
enum HandoffRead<Value> {
    case absent                       // nothing has written this file: the ordinary idle state
    case unreadable(reason: String)   // it IS there, and could not be read
    case read(Value)

    var value: Value? {
        guard case .read(let value) = self else { return nil }
        return value
    }

    // For a caller whose correct behaviour really is the same either way. Named so that reading it says
    // out loud that the two states were considered, rather than a `try?` that says nothing.
    var valueIgnoringFailure: Value? { value }
}

// Conditional, so this reader works for any decoded type. Requiring Equatable up front would have
// excluded the several handoff shapes that are not, and pushed those sites back to a `try?`.
extension HandoffRead: Sendable where Value: Sendable {}
extension HandoffRead: Equatable where Value: Equatable {}

enum HandoffFile {

    static func data(at url: URL, recorder: HandoffReadFailures = .shared) -> HandoffRead<Data> {
        read(at: url, recorder: recorder) { $0 }
    }

    // For a caller that has already read the bytes and fails LATER, decoding or ingesting them. The
    // existence check is what keeps an absent file out of the register: a caller in this position cannot
    // otherwise tell the two apart either.
    static func recordFailure(at url: URL, error: any Error, recorder: HandoffReadFailures = .shared) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        recorder.record(file: url.lastPathComponent, reason: HandoffDecodeFailure.describe(error))
    }

    static func read<T>(at url: URL,
                        recorder: HandoffReadFailures = .shared,
                        decode: (Data) throws -> T) -> HandoffRead<T> {
        let name = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Absent is the ordinary state and clears any earlier failure for this file: a file that is
            // gone is no longer one Overture cannot read, and leaving the record standing would keep a
            // warning on screen that nothing could ever clear.
            guard FileManager.default.fileExists(atPath: url.path) else {
                recorder.clear(file: name)
                return .absent
            }
            let reason = HandoffDecodeFailure.describe(error)
            recorder.record(file: name, reason: reason)
            return .unreadable(reason: reason)
        }
        do {
            let value = try decode(data)
            recorder.clear(file: name)
            return .read(value)
        } catch {
            let reason = HandoffDecodeFailure.describe(error)
            recorder.record(file: name, reason: reason)
            return .unreadable(reason: reason)
        }
    }
}

// The files Overture currently cannot read, so a read that legitimately carries on quietly still leaves
// a trace somebody can see (#2879).
//
// Keyed by filename and CLEARED by a successful read of that file, never by a timer: the condition ends
// when the file becomes readable, and nothing else is evidence of that. A repeat is counted rather than
// duplicated, because these reads happen on a poll and a list of two hundred identical lines is a list
// nobody reads (L36).
final class HandoffReadFailures: @unchecked Sendable {

    struct Failure: Equatable, Sendable {
        var file: String
        var reason: String
        var count: Int
    }

    // Injectable rather than only a singleton, so a test never reads or writes the register another test
    // is using (L2). Every call site takes it as a defaulted parameter.
    static let shared = HandoffReadFailures()

    // The two exemptions, each NAMED for the reason it does not report, so a read that stays quiet says
    // out loud why rather than looking like one somebody forgot. A silent exemption is how a sweep like
    // this ends up covering only the sites nobody had a reason to skip.
    //
    // A file being read WHILE the run is writing it. The three progress files are rewritten from the
    // results file after every item and polled by the toolbar's live label, so catching one half-written
    // is the ordinary case, not a fault, and reporting it would put a warning on screen during every
    // healthy run (L36). What those files report is DERIVED from a results file that is recorded, so a
    // genuinely broken run is still surfaced, by its own results.
    static let readWhileBeingWritten = HandoffReadFailures(recording: false)

    // A file whose read failure ALREADY has its own line, written for it and saying more than a generic
    // one could. Recording it too would put the same fault on the masthead twice in two wordings (#843).
    static let reportedByItsOwnSurface = HandoffReadFailures(recording: false)

    private let lock = NSLock()
    private let recording: Bool
    private var failures: [String: Failure] = [:]

    init(recording: Bool = true) {
        self.recording = recording
    }

    func record(file: String, reason: String) {
        guard recording else { return }
        lock.lock()
        defer { lock.unlock() }
        let previous = failures[file]
        failures[file] = Failure(file: file, reason: reason, count: (previous?.count ?? 0) + 1)
    }

    func clear(file: String) {
        lock.lock()
        defer { lock.unlock() }
        failures[file] = nil
    }

    // Sorted by filename so the surface reading this is stable between polls rather than reshuffling.
    func current() -> [Failure] {
        lock.lock()
        defer { lock.unlock() }
        return failures.values.sorted { $0.file < $1.file }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        failures = [:]
    }
}
