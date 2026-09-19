// Ported-From: danwright32/overture mac/Overture/Domain/ReplyDetection.swift @ 0bb3869c8f71777d08712e9fa146fd07c6da699f
//
// Ported on 2026-09-19 by backstage#2 (step 3). ONE PREDICATE, NOT THE FILE: `labelIds(of:)`,
// `isDraft` and `wasSentByUser` from the origin's reply detection, as a shared definition, so Ovation
// does not become a third implementation of it and the origin inherits this one when it migrates
// (L181, L263). The rest of that file is the origin's reply classification and stays behind. The
// logic and its reasoning are the origin's, unchanged; only the enclosing name is new, and the
// functions are public because a consumer calls them to decide whether an invoice was sent.
import Foundation

public enum GmailSentStatus {

    // Origin #2918: Gmail returns UNSENT DRAFTS inside a thread's messages, alongside real mail. A
    // draft carries the sender's own address and a newer date, so every attribute but its labels makes
    // it look sent. A message the mailbox really sent carries SENT; one still being composed carries
    // DRAFT.
    //
    // The labels of a message, or nil when the message carries no labelIds field at all. The two are
    // kept apart deliberately, because that distinction is the whole of the rule below: an EMPTY list is
    // Gmail saying the message has no labels, and a MISSING one is Gmail not having been asked, or a
    // shape nobody here has seen. Upper cased, since these are Gmail's own constants.
    public static func labelIds(of message: [String: Any]) -> [String]? {
        guard let raw = message["labelIds"] as? [Any] else { return nil }
        return raw.compactMap { $0 as? String }.map { $0.uppercased() }
    }

    // A message Gmail is holding as an unsent draft. False when the labels are missing, because an
    // absent field is not a claim either way and the refusal below is what fails closed on it.
    public static func isDraft(_ message: [String: Any]) -> Bool {
        labelIds(of: message)?.contains("DRAFT") ?? false
    }

    // Did the mailbox actually SEND this message? It FAILS CLOSED: no label information means refused,
    // not accepted. The two directions are not symmetrical: a message wrongly accepted marks something
    // sent that never left, permanently and silently, while a message wrongly refused leaves a question
    // open that a person can see and settle (L42, L98).
    public static func wasSentByUser(_ message: [String: Any]) -> Bool {
        guard let labels = labelIds(of: message) else { return false }
        return labels.contains("SENT") && !labels.contains("DRAFT")
    }
}
