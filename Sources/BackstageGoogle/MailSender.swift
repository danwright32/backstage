// Ported-From: danwright32/overture mac/Overture/Integration/MailSender.swift @ 0bb3869c8f71777d08712e9fa146fd07c6da699f
//
// Ported on 2026-09-19 by backstage#2. Do not edit this copy to fix a fault that is also in
// the origin: fix it there and re-port (L263).
//
// TWO DELIBERATE CHANGES. The origin's header comment named its own sending mailbox, which a shared
// package must not carry and this repository's own secrets guard refuses. And its refusal message
// named that app's account; this one is shown by three apps, so it says only what is true of all.
// The types are public, since they are the send API every consumer builds against.
import Foundation

// The seam between a consumer and actually sending mail. A real implementation calls the Gmail API
// for whichever account the consumer authorized. Until one is connected, NotConfiguredSender lets the
// whole send pipeline build, test and run without sending anything.

public struct OutgoingMail: Equatable, Sendable {
    // #2030: a list, because one message can name several people (milestone "One email to several
    // contacts"). Private(set) with a failable init below, so a mail with nobody to send to cannot be
    // constructed at all rather than reaching Gmail with an empty addressee.
    public private(set) var to: [String]
    public var subject: String
    public var body: String
    // Threading (#74): a follow-up replies onto the original thread with `inReplyTo` + `threadId`.
    //
    // #2672: there is no `messageID` here any more. It was the caller's chance to STAMP a message with an
    // id of its own, and #2647 established that Gmail discards a client-supplied Message-ID and assigns
    // its own, so a value put here has never been on the wire. Nothing had set it since, which left a
    // field that read as a working seam, was threaded all the way down into the RFC822 headers, and could
    // only ever invite somebody to use it on the one path that throws it away (L29, L46). The id that
    // matters is the one read BACK off the send, which is `SentReceipt.messageID`.
    public var inReplyTo: String? = nil
    // #2648: the WHOLE ancestry of this message, oldest first, space separated. `inReplyTo` is the
    // immediate parent only, which is all RFC 2822 lets that header carry; `References` is defined as the
    // chain back to the first message, and a third message naming only the second gives a client that
    // threads by walking the chain no link back to the first. Nil on a first send, which has no ancestry.
    public var references: String? = nil
    public var threadId: String? = nil

    // Nil when there is nobody to send to. A mail with no addressee is not a mail, and the alternative
    // (constructing one and finding out at the Gmail API, or worse not finding out) puts the discovery
    // after the point where a caller has already recorded that something went out.
    //
    // A blank ALONGSIDE a real address is dropped rather than refused: the person named still gets their
    // email, and nothing empty reaches the header.
    //
    // #2052: nil for a blank SUBJECT too, on the same reasoning. This is the boundary every send path
    // passes through (a pitch, a joint pitch, a follow-up, a conversation note, a reply), so it is the one
    // place that can promise no email leaves under Dan's name with an empty `Subject:` header, whatever
    // the screen above it did. The subject is kept verbatim rather than trimmed here: what he approved is
    // what sends, and this only decides whether there is one at all.
    public init?(to: [String], subject: String, body: String,
          inReplyTo: String? = nil, references: String? = nil,
          threadId: String? = nil) {
        let addresses = to.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !addresses.isEmpty,
              !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.to = addresses
        self.subject = subject
        self.body = body
        self.inReplyTo = inReplyTo
        self.references = references
        self.threadId = threadId
    }
}

// #2648: how a reply's `References` header is built, in ONE place, so the three send paths that reply onto
// a conversation (the nudge, the closing note, the reply draft) cannot disagree about what the chain is.
//
// RFC 2822: a reply's References is its parent's References followed by its parent's Message-ID, oldest
// first. Overture already sends three message conversations (a pitch, a nudge, a closing note), and
// `sendFollowUp` re-stamps the contact's stored id with the nudge's, so before this the closing note
// referenced the nudge and nothing earlier. A client that threads by walking the chain then had no link
// from the third message back to the first.
public enum MailThreading {
    public static func references(parentReferences: String?, parentMessageID: String?) -> String? {
        let parts = [parentReferences, parentMessageID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

public struct SentReceipt: Equatable, Sendable {
    public var threadId: String
    public var messageID: String? = nil   // the Message-ID stamped on the sent message, for threading (#74)
    // True when the send succeeded (2xx) but the response body had no parseable threadId (#483):
    // threadId is "" in this case, never a guess, so the caller can flag it instead of leaving
    // reply watching silently and permanently broken for that recipient.
    public var threadIdDegraded: Bool = false
    // #2647: true when the send succeeded but the REAL Message-ID could not be read back off the sent
    // message, so `messageID` is nil rather than a value nothing on the wire ever carried. Its OWN flag
    // beside threadIdDegraded, not folded into it: they are two independent checks with two different
    // consequences (replies cannot be watched, versus our next message cannot thread onto this one), and
    // one field standing for both would let a pass on either erase the other's failure (L53).
    public var messageIDDegraded: Bool = false

    public init(threadId: String, messageID: String? = nil,
                threadIdDegraded: Bool = false, messageIDDegraded: Bool = false) {
        self.threadId = threadId
        self.messageID = messageID
        self.threadIdDegraded = threadIdDegraded
        self.messageIDDegraded = messageIDDegraded
    }
}

public protocol MailSender: Sendable {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt
}

public enum MailSenderError: LocalizedError, Equatable {
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Gmail isn't connected yet. Connect a Gmail account to enable sending."
        }
    }
}

// Default until Gmail is authorized: refuses to send, so nothing leaves by accident.
public struct NotConfiguredSender: MailSender {
    public init() {}

    public func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        throw MailSenderError.notConfigured
    }
}
