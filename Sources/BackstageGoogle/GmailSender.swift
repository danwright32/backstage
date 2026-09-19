// Ported-From: danwright32/overture mac/Overture/Integration/GmailSender.swift @ 0bb3869c8f71777d08712e9fa146fd07c6da699f
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
        self.fetch = fetch ?? { try await GmailNetworking.session.data(for: $0) }
        self.onAuthExpired = onAuthExpired
    }

    public func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        let resolved = try await token()
        return try await GmailSender.performSend(
            mail: mail, fromName: fromName, fromEmail: fromEmail, token: resolved,
            signature: signature, fetch: fetch, onAuthExpired: onAuthExpired)
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
        // Origin #2647: nothing is minted here. Gmail DISCARDS a client supplied Message-ID on
        // users/me/messages/send and assigns its own, measured on a live mailbox 2026-08-13, so a
        // minted value has never been on the wire. The real id is read back below instead.
        let raw = GmailMessage.rawField(
            fromName: fromName, fromEmail: fromEmail,
            to: mail.to, subject: mail.subject, body: mail.body,
            signature: signature,
            inReplyTo: mail.inReplyTo, references: mail.references)

        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Including the original threadId tells Gmail to append this message to that conversation.
        var payload: [String: Any] = ["raw": raw]
        if let threadId = mail.threadId { payload["threadId"] = threadId }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

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

public enum GmailSendError: LocalizedError, Equatable {
    case api(String)
    case authExpired
    public var errorDescription: String? {
        switch self {
        case .api(let m): return m
        case .authExpired: return "Gmail access expired or was revoked, so it needs connecting again."
        }
    }
}
