import Foundation

// A reader for the wire form, written from RFC 2045 and 2046 rather than from the producer.
//
// It exists so backstage#51's attachment tests can DECODE what GmailMessage produced and assert on
// the parts that came back, instead of asserting the produced string contains what the same change
// just wrote into it (L52). Its own calibration lives in MIMEReaderTests: it is proved against a
// message written by hand, carrying shapes this repository never emits, before anything here is
// pointed at this repository's output.
//
// IT REFUSES RATHER THAN RETURNING AN EMPTY ANSWER. Every way this can fail to understand a
// message throws, because a reader that answered "no parts" for a multipart it could not split
// would make "the parts are right" pass hardest on the messages that are most broken (L98, L215).
enum MIMEReader {

    enum Failure: Error, Equatable {
        case noHeaderBreak
        case multipartWithoutBoundary
        case boundaryNeverOpened(String)
        case multipartNeverClosed(String)
        case undecodableBase64
        case unsupportedTransferEncoding(String)
    }

    struct Part {
        var headers: [(name: String, value: String)]
        // Lowercased and without its parameters. "text/plain" when no Content-Type is given, which
        // is what RFC 2045 says an absent one means.
        var contentType: String
        // The Content-Type parameters, unquoted, and percent decoded when given RFC 2231 style.
        var parameters: [String: String]
        var dispositionParameters: [String: String]
        // Decoded per Content-Transfer-Encoding, so an attachment's bytes come back as its bytes.
        var body: Data
        // Empty unless this is a multipart.
        var parts: [Part]

        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        var text: String { String(decoding: body, as: UTF8.self) }

        // RFC 2231's `filename*` wins over `filename`, which is the order a receiver applies.
        var dispositionFilename: String? {
            dispositionParameters["filename*"] ?? dispositionParameters["filename"]
        }

        var disposition: String? {
            header("Content-Disposition").map { String($0.prefix { $0 != ";" }).trimmed() }
        }
    }

    static func parse(_ message: String) throws -> Part {
        // SPLIT ON CRLF ALONE, which is what the standard defines a line to be. A bare LF inside a
        // body then stays inside that body rather than being read as structure, which is the
        // strictest honest reading and the one that makes a producer emitting the wrong line ending
        // fail here rather than at a mail server.
        try parse(lines: message.components(separatedBy: "\r\n"))
    }

    private static func parse(lines: [String]) throws -> Part {
        guard let headerBreak = lines.firstIndex(of: "") else { throw Failure.noHeaderBreak }
        let headers = unfold(Array(lines[..<headerBreak]))
        let bodyLines = Array(lines[(headerBreak + 1)...])

        let typeHeader = headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        let contentType = (typeHeader.map { String($0.prefix { $0 != ";" }).trimmed().lowercased() })
            ?? "text/plain"
        let parameters = parameters(of: typeHeader)
        let dispositionParameters = self.parameters(
            of: headers.first { $0.name.caseInsensitiveCompare("Content-Disposition") == .orderedSame }?.value)

        if contentType.hasPrefix("multipart/") {
            guard let boundary = parameters["boundary"] else { throw Failure.multipartWithoutBoundary }
            return Part(headers: headers, contentType: contentType, parameters: parameters,
                        dispositionParameters: dispositionParameters,
                        body: Data(bodyLines.joined(separator: "\r\n").utf8),
                        parts: try parts(of: bodyLines, on: boundary).map { try parse(lines: $0) })
        }

        return Part(headers: headers, contentType: contentType, parameters: parameters,
                    dispositionParameters: dispositionParameters,
                    body: try decode(bodyLines, headers: headers),
                    parts: [])
    }

    // The lines of each part, in order. The preamble before the first delimiter and the epilogue
    // after the closing one are dropped, which is what RFC 2046 says they are for.
    private static func parts(of bodyLines: [String], on boundary: String) throws -> [[String]] {
        // Trailing whitespace after a delimiter is permitted, so a comparison that did not allow
        // for it would read a perfectly legal message as having no parts at all.
        let isOpen = { (line: String) in line.trimmedTrailing() == "--" + boundary }
        let isClose = { (line: String) in line.trimmedTrailing() == "--" + boundary + "--" }
        guard bodyLines.contains(where: isOpen) else { throw Failure.boundaryNeverOpened(boundary) }
        var parts: [[String]] = []
        var current: [String]?
        for line in bodyLines {
            if isClose(line) {
                if let c = current { parts.append(c) }
                return parts
            }
            if isOpen(line) {
                if let c = current { parts.append(c) }
                current = []
                continue
            }
            current?.append(line)
        }
        throw Failure.multipartNeverClosed(boundary)
    }

    private static func decode(_ bodyLines: [String], headers: [(name: String, value: String)]) throws -> Data {
        let encoding = (headers.first { $0.name.caseInsensitiveCompare("Content-Transfer-Encoding") == .orderedSame }?
            .value.trimmed().lowercased()) ?? "7bit"
        switch encoding {
        case "base64":
            let joined = bodyLines.map { $0.trimmed() }.joined()
            guard let data = Data(base64Encoded: joined) else { throw Failure.undecodableBase64 }
            return data
        case "7bit", "8bit", "binary":
            return Data(bodyLines.joined(separator: "\r\n").utf8)
        default:
            // NAMED RATHER THAN READ AS RAW BYTES. An encoding this does not implement returning the
            // encoded text would make a producer's mistake and this reader's gap look identical.
            throw Failure.unsupportedTransferEncoding(encoding)
        }
    }

    // A continuation line, one starting with whitespace, belongs to the header above it.
    private static func unfold(_ lines: [String]) -> [(name: String, value: String)] {
        var out: [(name: String, value: String)] = []
        for line in lines {
            if let first = line.first, first == " " || first == "\t", !out.isEmpty {
                out[out.count - 1].value += " " + line.trimmed()
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            out.append((name: String(line[..<colon]).trimmed(),
                        value: String(line[line.index(after: colon)...]).trimmed()))
        }
        return out
    }

    // Everything after the first `;`, as name/value pairs. Lowercased names, because a parameter
    // name is case insensitive and a lookup that missed on `Name=` would report a filename as absent.
    private static func parameters(of header: String?) -> [String: String] {
        guard let header else { return [:] }
        var out: [String: String] = [:]
        for field in splitOnSemicolonsOutsideQuotes(header).dropFirst() {
            guard let equals = field.firstIndex(of: "=") else { continue }
            let name = String(field[..<equals]).trimmed().lowercased()
            let raw = String(field[field.index(after: equals)...]).trimmed()
            out[name] = name.hasSuffix("*") ? extendedValue(raw) : unquote(raw)
        }
        return out
    }

    private static func splitOnSemicolonsOutsideQuotes(_ s: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for c in s {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" && inQuotes { current.append(c); escaped = true; continue }
            if c == "\"" { inQuotes.toggle(); current.append(c); continue }
            if c == ";" && !inQuotes { fields.append(current); current = ""; continue }
            current.append(c)
        }
        fields.append(current)
        return fields
    }

    private static func unquote(_ s: String) -> String {
        guard s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 else { return s }
        var out = ""
        var escaped = false
        for c in s.dropFirst().dropLast() {
            if escaped { out.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            out.append(c)
        }
        return out
    }

    // RFC 2231: charset'language'percent-encoded-octets.
    private static func extendedValue(_ s: String) -> String {
        let pieces = s.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        let encoded = pieces.count == 3 ? String(pieces[2]) : s
        return encoded.removingPercentEncoding ?? encoded
    }
}

private extension String {
    func trimmed() -> String { trimmingCharacters(in: .whitespaces) }
    func trimmedTrailing() -> String {
        var s = self
        while let last = s.last, last == " " || last == "\t" { s.removeLast() }
        return s
    }
}
