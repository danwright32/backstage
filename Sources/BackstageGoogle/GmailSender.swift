// Ported-From: danwright32/overture mac/Overture/Integration/GmailSender.swift @ 0bb3869c8f71777d08712e9fa146fd07c6da699f
// Ported-Adapted: 34429e12de71ef24ed71db16286c54f02f661ce60009af79595ecea1549c0eef
//
// Ported on 2026-09-19 by backstage#2 (step 3). Do not edit this copy to fix a fault that is also in
// the origin: fix it there and re-port (L263).
//
// DELIBERATE CHANGES, each because the package carries no consumer's content and owns no consumer's
// state:
//   1. No default sender name. The origin defaulted to its owner's own name; each consumer says who
//      it is sending as.
//   2. The token, the auth expired hook and the signature are the CONSUMER's, handed in. The origin
//      reached for its own auth manager's global instance and its own signature store; a package
//      cannot know either. The auth manager that supplies the token is step 4.
//   3. The origin's log calls are gone. The one that mattered, a read back that failed, is already
//      carried by the receipt's messageIDDegraded flag, which a consumer can act on and a log line
//      could not.
//   4. The expired message no longer tells the reader to click a button the origin's screen has.
// The send, the response handling and the read back are otherwise exactly the origin's.
//
// A FIFTH, ADDED ON 2026-09-21 BY backstage#51: the request body is built by a function of its own
// and REFUSED when it is over what Gmail accepts, because a mail can now carry an attachment. Not a
// fault in the origin, which cannot attach anything and so cannot reach the limit; a consequence of
// a capability only this copy has. Adapted deliberately, with the digest re-recorded, which is the
// route backstage#51 chose before the work started rather than when a gate refused (L263).
import Foundation

// The live MailSender: sends an approved message through the Gmail API. Fully async: it awaits the
// access token then the send, so a caller on the main actor never blocks the main thread. An earlier
// synchronous semaphore bridge deadlocked in the origin: the blocked main thread could not service the
// main actor token work it was waiting on.
public struct GmailSender: MailSender {
    public var fromName: String
    public var fromEmail: String
    public var signature: MessageSignature
    // Every outside dependency is handed in, so the send the consumer drives is testable without the
    // network or a live login (origin #194), and so the package never reaches for a login it does not
    // own.
    public var token: @Sendable () async throws -> String
    public var fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public var onAuthExpired: @Sendable () async -> Void

    public init(fromName: String, fromEmail: String, signature: MessageSignature = .none,
                token: @escaping @Sendable () async throws -> String,
                // Nil means the package's own bounded session (every call capped at 30 seconds).
                fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
                onAuthExpired: @escaping @Sendable () async -> Void) {
        self.fromName = fromName
        self.fromEmail = fromEmail
        self.signature = signature
        self.token = token
        // The live default refuses inside a test run (backstage#5), so a test that forgets to inject
        // a fetch fails by name instead of sending real mail.
        self.fetch = fetch ?? { try await GmailNetworking.live($0) }
        self.onAuthExpired = onAuthExpired
    }

    public func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        let resolved = try await token()
        return try await GmailSender.performSend(
            mail: mail, fromName: fromName, fromEmail: fromEmail, token: resolved,
            signature: signature, fetch: fetch, onAuthExpired: onAuthExpired)
    }

    // The exact bytes that would be POSTed, or a refusal because they are over what Gmail accepts.
    //
    // MEASURED ON THE REQUEST, NEVER ON THE FILE. backstage#51: an attachment grows roughly four
    // fifths on the way here. It is base64 encoded into its own part, wrapped at 76, then the whole
    // RFC 2822 message is base64url encoded into `raw`, then that is JSON escaped. A guard written
    // against the attachment's own byte count admits a file that arrives over the limit and gets
    // exactly the opaque 400 it exists to prevent, while reading as protection (L81, L63).
    //
    // Its own function, and internal rather than private, so the size can be measured in a test
    // without a fetch and so the one number the refusal is about is the one the request carries.
    static func encodedRequestBody(mail: OutgoingMail, fromName: String, fromEmail: String,
                                   signature: MessageSignature) throws -> Data {
        // Origin #2647: nothing is minted here. Gmail DISCARDS a client supplied Message-ID on
        // users/me/messages/send and assigns its own, measured on a live mailbox 2026-08-13, so a
        // minted value has never been on the wire. The real id is read back after the send instead.
        let raw = GmailMessage.rawField(
            fromName: fromName, fromEmail: fromEmail,
            to: mail.to, subject: mail.subject, body: mail.body,
            signature: signature, attachments: mail.attachments,
            inReplyTo: mail.inReplyTo, references: mail.references)
        // Including the original threadId tells Gmail to append this message to that conversation.
        var payload: [String: Any] = ["raw": raw]
        if let threadId = mail.threadId { payload["threadId"] = threadId }
        let body = try JSONSerialization.data(withJSONObject: payload)
        guard body.count <= GmailSendLimits.maxRequestBytes else {
            throw GmailSendError.tooLarge(encodedBytes: body.count,
                                          limitBytes: GmailSendLimits.maxRequestBytes)
        }
        return body
    }

    // The testable core: encode the message, POST it, and interpret the response (success, api
    // error, or auth expired). The HTTP fetch and the auth expired hook are injected so a fake
    // response can drive each path without the network or a live token.
    @MainActor
    static func performSend(
        mail: OutgoingMail,
        fromName: String,
        fromEmail: String,
        token: String,
        signature: MessageSignature = .none,
        fetch: (URLRequest) async throws -> (Data, URLResponse),
        onAuthExpired: () async -> Void
    ) async throws -> SentReceipt {
        // BUILT AND MEASURED BEFORE ANYTHING IS SENT (backstage#51). A body over what Gmail accepts
        // is refused here rather than posted and answered with an opaque 400.
        let body = try encodedRequestBody(mail: mail, fromName: fromName, fromEmail: fromEmail,
                                          signature: signature)

        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, resp) = try await fetch(req)
        let http = resp as? HTTPURLResponse
        if http?.statusCode == 401 {
            // 401 = the token was revoked or expired since it was issued. The consumer is told, so it
            // can show disconnected. NOT 403: Gmail uses 403 for rate limits and permission issues,
            // which a reconnect will not fix and which must not sign anybody out mid batch.
            await onAuthExpired()
            throw GmailSendError.authExpired
        }
        guard let http, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "send failed"
            throw GmailSendError.api(detail)
        }
        let json = ResponseBody.json(data, from: "gmail.messages.send").value
        let sentMessageId = json?["id"] as? String
        let realMessageID = await readBackMessageID(
            sentMessageId: sentMessageId, token: token, fetch: fetch)
        if let threadId = (json?["threadId"] as? String) ?? sentMessageId, !threadId.isEmpty {
            return SentReceipt(threadId: threadId, messageID: realMessageID,
                               messageIDDegraded: realMessageID == nil)
        }
        // Origin #483: the send itself succeeded, so this must never throw, but a body with no
        // readable threadId leaves reply watching with nothing to watch. Come back flagged rather than
        // silently empty.
        return SentReceipt(threadId: "", messageID: realMessageID, threadIdDegraded: true,
                           messageIDDegraded: realMessageID == nil)
    }

    // Origin #2647: the Message-ID Gmail actually stamped on the message it just sent, or nil.
    //
    // Nil is the whole point of the return type. Falling back to anything would hand every reader
    // downstream a value indistinguishable from a real one that references a message existing nowhere.
    // The caller flags the receipt instead (L11).
    //
    // Never throws: the SEND already succeeded by the time this runs, and failing to read a header back
    // must not be reported as failing to send an email that has gone.
    @MainActor
    private static func readBackMessageID(
        sentMessageId: String?,
        token: String,
        fetch: (URLRequest) async throws -> (Data, URLResponse)
    ) async -> String? {
        guard let id = sentMessageId, !id.isEmpty,
              let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/"
                            + escaped + "?format=metadata&metadataHeaders=Message-ID")
        else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await fetch(req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let json = ResponseBody.json(data, from: "gmail.messages.get").value
        let headers = (json?["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []
        // Case insensitively: header names are, and Gmail returns "Message-Id" as often as
        // "Message-ID", so an exact match would degrade a send that was perfectly fine.
        let value = headers.first {
            ($0["name"] as? String)?.caseInsensitiveCompare("Message-ID") == .orderedSame
        }?["value"] as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// What Gmail accepts in one send, backstage#51.
public enum GmailSendLimits {
    // A CONSERVATIVE FLOOR, NOT A DOCUMENTED LIMIT, and the difference is the whole of this note.
    //
    // 5 MB is the figure backstage#51 recorded for users.messages.send. Google's own reference for
    // that method was READ on 2026-09-21 and states no maximum upload size at all, and the
    // "Upload attachments" guide beside it gives 5 MB only as general advice about when a simple
    // upload is the right shape, never as this method's cap. So nothing here may be read as
    // "Gmail's limit is 5 MB": what is true is that this package sends at most 5 MB in one request,
    // which is at or below whatever Gmail's real ceiling is (L460, L249).
    //
    // THE ONLY THING THAT WOULD SETTLE IT is sending progressively larger mail through a live
    // mailbox and finding where Gmail starts refusing, which nothing here has done. Until somebody
    // does, a refusal at this number costs a person the ability to send a large file and never
    // costs them an opaque 400, which is the right side to be wrong on.
    //
    // 5,000,000 RATHER THAN 5 x 1024 x 1024, because the page says "5 MB" and does not say which
    // megabyte it means. The two readings differ by about 240 KB, and only one of the two errors is
    // harmless: refusing a message Gmail would have taken shows a person an honest refusal they can
    // act on, while accepting one it rejects gives them an opaque 400 from the API. So this takes
    // the smaller reading deliberately (L648).
    public static let maxRequestBytes = 5_000_000
}

public enum GmailSendError: LocalizedError, Equatable {
    case api(String)
    case authExpired
    // backstage#51. Both numbers are carried rather than only the message, so a consumer can show
    // its own surface without parsing this sentence back apart.
    case tooLarge(encodedBytes: Int, limitBytes: Int)
    public var errorDescription: String? {
        switch self {
        case .api(let m): return m
        case .authExpired: return "Gmail access expired or was revoked, so it needs connecting again."
        case .tooLarge(let encodedBytes, let limitBytes):
            // NAMES WHY THE TWO NUMBERS DIFFER FROM THE FILE ON DISK. Without that sentence this
            // accuses a 5 MB attachment of being 9 MB, which reads as a fault in the attachment and
            // sends somebody looking for one.
            // Says what this package does, not what Gmail permits: the ceiling here is a
            // conservative floor under an undocumented one, so a sentence attributing it to Gmail
            // would be claiming something nothing measured (L440).
            return "This message comes to \(megabytes(encodedBytes)) once encoded for sending, and "
                + "the most that can go in one send is \(megabytes(limitBytes)). Attachments grow by "
                + "roughly four fifths on the way, so a file well under that can still be too big. "
                + "Send a smaller file, or fewer of them."
        }
    }

    private func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}
