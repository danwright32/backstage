// Ported-From: danwright32/overture mac/Overture/Domain/HandoffDecodeFailure.swift @ 0bb3869c8f71777d08712e9fa146fd07c6da699f
//
// Ported on 2026-09-19 by backstage#2. Do not edit this copy to fix a fault that is also in
// the origin: fix it there and re-port (L263).
//
// TAKEN WHOLE AND UNCHANGED. Internal: no consumer needs to name it.
import Foundation

// Why a handoff file could not be read, in words that name the FIELD (#2873).
//
// Every handoff file in this repo is written by something outside the app (a detached AI run, a
// launcher script, an importer) and read through a decoder that can throw. A `DecodingError`'s
// `localizedDescription` is the same sentence whatever went wrong ("The data couldn't be read because
// it isn't in the correct format"), so it cannot say which field is missing, and that one fact is the
// whole of what makes such a failure actionable.
//
// #2873 is the cost of not having this: the reply drafter stopped writing one metadata field, the
// decoder threw `keyNotFound("generatedAt")` on every real results file, the throw was discarded by a
// `try?`, and every AI reply draft was dropped in silence while the sheet showed a spinner for it. The
// field was never named anywhere, which is why it took a day to find.
//
// Pure and shared on purpose: #2879 sweeps the other ingest sites, and each one needs the same sentence
// rather than its own.
enum HandoffDecodeFailure {

    static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else {
            // #2879: a file the app could not OPEN at all (permissions, a path that is a directory, a
            // volume that went away) arrives here too. Those carry a real sentence from the OS, so it is
            // used. A native Swift error does not: its localizedDescription is the generic
            // "The operation couldn't be completed", where its own description states the actual reason,
            // which is why ReplyClassifyResultsError spells its version refusal out.
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain || ns.domain == NSURLErrorDomain {
                return ns.localizedDescription
            }
            return String(describing: error)
        }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "a required field is missing: \(path(context, adding: key))"
        case .valueNotFound(_, let context):
            return "a required field is empty: \(path(context))"
        case .typeMismatch(let type, let context):
            return "\(path(context)) is not the expected type (\(type))"
        case .dataCorrupted(let context):
            let where_ = path(context)
            return where_.isEmpty ? "it is not valid JSON" : "\(where_) could not be read"
        @unknown default:
            return String(describing: decoding)
        }
    }

    // The coding path as a person would write it: `results[0].naturalKey`, never an array of keys.
    private static func path(_ context: DecodingError.Context, adding key: (any CodingKey)? = nil) -> String {
        let keys = context.codingPath + (key.map { [$0] } ?? [])
        var out = ""
        for k in keys {
            if let index = k.intValue {
                out += "[\(index)]"
            } else {
                out += out.isEmpty ? k.stringValue : ".\(k.stringValue)"
            }
        }
        return out
    }
}
