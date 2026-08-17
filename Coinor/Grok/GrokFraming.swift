import Foundation

/// Message framing for Grok's stdio agent transport.
///
/// Grok reads its standard input one `\n`-terminated line at a time and writes
/// each outgoing message followed by `\n`, so Coinor writes newline-delimited
/// JSON. The decoder additionally accepts `Content-Length` header frames: the
/// same JSON-RPC stream is header-framed by other ACP transports, and a stray
/// header block would otherwise be silently mis-read as message content.
enum GrokFraming {
    static let maximumFrameSize = 64 * 1024 * 1024
    static let maximumHeaderSize = 8 * 1024

    static let contentLengthHeader = "Content-Length"

    /// Frames one already-serialized JSON payload for Grok's stdin.
    static func encode(_ payload: Data) -> Data {
        var framed = Data(capacity: payload.count + 1)
        framed.append(payload)
        framed.append(0x0A)
        return framed
    }
}

/// Incremental decoder for the inbound half of the stream.
///
/// Pipe reads split wherever the kernel happens to split them, so a chunk can
/// carry a fraction of one message, several whole messages, or both.
struct GrokFrameDecoder {
    private var buffer: [UInt8] = []
    private let maximumFrameSize: Int

    init(maximumFrameSize: Int = GrokFraming.maximumFrameSize) {
        self.maximumFrameSize = maximumFrameSize
    }

    /// Appends a chunk and returns every complete payload it finished.
    mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(contentsOf: chunk)
        var frames: [Data] = []
        while let frame = try nextFrame() {
            frames.append(frame)
        }
        if buffer.count > maximumFrameSize {
            throw GrokControlError.frameTooLarge(buffer.count)
        }
        return frames
    }

    private mutating func nextFrame() throws -> Data? {
        dropLeadingTerminators()
        guard let first = buffer.first else { return nil }
        if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            return try takeLineFrame()
        }
        return try takeHeaderFrame()
    }

    private mutating func dropLeadingTerminators() {
        var index = 0
        while index < buffer.count, buffer[index] == 0x0A || buffer[index] == 0x0D {
            index += 1
        }
        if index > 0 {
            buffer.removeFirst(index)
        }
    }

    private mutating func takeLineFrame() throws -> Data? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        var end = newline
        if end > 0, buffer[end - 1] == 0x0D {
            end -= 1
        }
        // A line that already exceeds the frame size before its terminating
        // newline arrives is rejected the same way one that arrives whole is.
        if end > maximumFrameSize {
            throw GrokControlError.frameTooLarge(end)
        }
        let payload = Data(buffer[0 ..< end])
        buffer.removeFirst(newline + 1)
        return payload
    }

    private mutating func takeHeaderFrame() throws -> Data? {
        guard let headerEnd = headerTerminator() else {
            if buffer.count > GrokFraming.maximumHeaderSize {
                throw GrokControlError.malformedFrame("header block exceeded \(GrokFraming.maximumHeaderSize) bytes")
            }
            return nil
        }
        let headerBytes = Data(buffer[0 ..< headerEnd.start])
        guard let headerText = String(data: headerBytes, encoding: .utf8) else {
            throw GrokControlError.malformedFrame("header block is not valid UTF-8")
        }
        guard let length = contentLength(in: headerText) else {
            throw GrokControlError.malformedFrame("expected a JSON message or a Content-Length header, got \(headerText.prefix(64))")
        }
        guard length >= 0 else {
            throw GrokControlError.malformedFrame("Content-Length cannot be negative")
        }
        guard length <= maximumFrameSize else {
            throw GrokControlError.frameTooLarge(length)
        }
        let bodyStart = headerEnd.end
        let (end, overflow) = bodyStart.addingReportingOverflow(length)
        guard !overflow else {
            throw GrokControlError.malformedFrame("Content-Length \(length) overflows the frame bounds")
        }
        guard buffer.count >= end else { return nil }
        let payload = Data(buffer[bodyStart ..< end])
        buffer.removeFirst(end)
        return payload
    }

    /// Locates the blank line that closes a header block, tolerating either
    /// CRLF or bare LF line endings.
    private func headerTerminator() -> (start: Int, end: Int)? {
        var candidates: [(start: Int, end: Int)] = []
        if let range = buffer.firstRange(of: [0x0D, 0x0A, 0x0D, 0x0A]) {
            candidates.append((range.lowerBound, range.upperBound))
        }
        if let range = buffer.firstRange(of: [0x0A, 0x0A]) {
            candidates.append((range.lowerBound, range.upperBound))
        }
        return candidates.min { $0.start < $1.start }
    }

    private func contentLength(in headerText: String) -> Int? {
        for line in headerText.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            guard parts[0].trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(GrokFraming.contentLengthHeader) == .orderedSame
            else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
