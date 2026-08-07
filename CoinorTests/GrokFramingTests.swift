import Foundation
import Testing

@testable import Coinor

private func decode(_ decoder: inout GrokFrameDecoder, _ text: String) throws -> [String] {
    try decoder.append(Data(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
}

@Test
func encodesOneNewlineTerminatedLine() {
    let payload = Data(#"{"id":"coinor-1"}"#.utf8)
    let framed = GrokFraming.encode(payload)

    #expect(framed.last == 0x0A)
    #expect(framed.dropLast() == payload)
    #expect(framed.count == payload.count + 1)
}

@Test
func decodesEveryMessageInOneChunk() throws {
    var decoder = GrokFrameDecoder()

    let frames = try decode(&decoder, "{\"id\":1}\n{\"id\":2}\n{\"id\":3}\n")

    #expect(frames == ["{\"id\":1}", "{\"id\":2}", "{\"id\":3}"])
}

@Test
func holdsAPartialMessageUntilItsTerminatorArrives() throws {
    var decoder = GrokFrameDecoder()

    #expect(try decode(&decoder, "{\"met") == [])
    #expect(try decode(&decoder, "hod\":\"x\"}") == [])
    #expect(try decode(&decoder, "\n{\"id\":2}\n") == ["{\"method\":\"x\"}", "{\"id\":2}"])
}

@Test
func keepsMultibyteTextIntactAcrossAChunkBoundary() throws {
    var decoder = GrokFrameDecoder()
    let message = "{\"title\":\"caf\u{00E9} \u{1F600}\"}"
    let bytes = Array(Data(message.utf8))

    _ = try decoder.append(Data(bytes[0 ..< 12]))
    let frames = try decoder.append(Data(bytes[12...]) + Data([0x0A]))

    #expect(frames.map { String(decoding: $0, as: UTF8.self) } == [message])
}

@Test
func skipsBlankLinesAndAcceptsCarriageReturns() throws {
    var decoder = GrokFrameDecoder()

    let frames = try decode(&decoder, "\n\r\n{\"id\":1}\r\n\n{\"id\":2}\n")

    #expect(frames == ["{\"id\":1}", "{\"id\":2}"])
}

@Test
func decodesContentLengthFramedMessages() throws {
    var decoder = GrokFrameDecoder()
    let body = "{\"id\":1}"

    let frames = try decode(
        &decoder,
        "Content-Length: \(body.utf8.count)\r\nContent-Type: application/vscode-jsonrpc\r\n\r\n\(body)"
    )

    #expect(frames == [body])
}

@Test
func decodesAContentLengthFrameSplitAcrossChunks() throws {
    var decoder = GrokFrameDecoder()

    #expect(try decode(&decoder, "Content-Length: 8\r\n") == [])
    #expect(try decode(&decoder, "\r\n{\"id\":") == [])
    #expect(try decode(&decoder, "1}") == ["{\"id\":1}"])
}

@Test
func decodesHeaderFramedAndLineFramedMessagesInTheSameStream() throws {
    var decoder = GrokFrameDecoder()

    let frames = try decode(&decoder, "Content-Length: 8\n\n{\"id\":1}{\"id\":2}\n")

    #expect(frames == ["{\"id\":1}", "{\"id\":2}"])
}

@Test
func rejectsAnOversizedDeclaredLength() {
    var decoder = GrokFrameDecoder(maximumFrameSize: 16)

    #expect(throws: GrokControlError.frameTooLarge(64)) {
        _ = try decode(&decoder, "Content-Length: 64\r\n\r\n")
    }
}

@Test
func rejectsAHeaderBlockThatNeverEnds() {
    var decoder = GrokFrameDecoder()
    let noise = String(repeating: "Content-Length: 8\r\n", count: 1024)

    #expect(throws: GrokControlError.self) {
        _ = try decode(&decoder, noise)
    }
}

@Test
func rejectsALeadingBlockThatIsNeitherJSONNorAHeader() {
    var decoder = GrokFrameDecoder()

    #expect(throws: GrokControlError.self) {
        _ = try decode(&decoder, "grok: could not start\r\n\r\n")
    }
}
