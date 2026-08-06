import Foundation
import Testing

@testable import CoinorHookRelayCore

@Test
func frameUsesBigEndianLengthAndPreservesPayload() throws {
    let payload = Data(#"{"hookEventName":"session_start"}"#.utf8)
    let frame = try FramedJSONCodec.frame(payload)

    #expect(Array(frame.prefix(4)) == [0, 0, 0, UInt8(payload.count)])
    #expect(frame.dropFirst(4) == payload)
}

@Test
func decoderAcceptsPartialAndMultipleFrames() throws {
    let first = Data(#"{"sessionId":"root"}"#.utf8)
    let second = Data(#"{"sessionId":"child"}"#.utf8)
    let bytes = try FramedJSONCodec.frame(first) + FramedJSONCodec.frame(second)
    var decoder = FramedJSONDecoder()

    #expect(try decoder.append(bytes.prefix(3)) == [])
    let decoded = try decoder.append(bytes.dropFirst(3))

    #expect(decoded == [first, second])
}

@Test
func configurationIsInertWithoutSocketAndClampsTimeout() {
    #expect(HookRelayConfiguration.from(environment: [:]) == nil)

    let low = HookRelayConfiguration.from(
        environment: [
            HookRelayConfiguration.socketPathEnvironmentKey: "/tmp/coinor.sock",
            HookRelayConfiguration.timeoutEnvironmentKey: "-5",
        ]
    )
    let high = HookRelayConfiguration.from(
        environment: [
            HookRelayConfiguration.socketPathEnvironmentKey: "/tmp/coinor.sock",
            HookRelayConfiguration.timeoutEnvironmentKey: "9000",
        ]
    )

    #expect(low?.timeoutMilliseconds == 1)
    #expect(high?.timeoutMilliseconds == 2_000)
}

@Test
func senderFailsQuicklyWhenNoListenerExists() {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sock")
        .path
    let started = ContinuousClock.now
    let delivered = NonblockingUnixSocketSender.send(
        payload: Data(#"{"hookEventName":"session_start"}"#.utf8),
        to: path,
        timeoutMilliseconds: 50
    )
    let elapsed = ContinuousClock.now - started

    #expect(delivered == false)
    #expect(elapsed < .milliseconds(250))
}
