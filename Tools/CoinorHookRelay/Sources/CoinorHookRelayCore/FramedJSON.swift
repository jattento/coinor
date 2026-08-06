import Foundation

public enum FramedJSONError: Error, Equatable {
    case payloadTooLarge(Int)
    case declaredPayloadTooLarge(Int)
}

public enum FramedJSONCodec {
    public static let headerSize = 4
    public static let maximumPayloadSize = 16 * 1024 * 1024

    public static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= maximumPayloadSize else {
            throw FramedJSONError.payloadTooLarge(payload.count)
        }

        var length = UInt32(payload.count).bigEndian
        var result = Data(bytes: &length, count: headerSize)
        result.append(payload)
        return result
    }
}

public struct FramedJSONDecoder {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []

        while buffer.count >= FramedJSONCodec.headerSize {
            let declaredLength = buffer.prefix(FramedJSONCodec.headerSize).reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            let payloadLength = Int(declaredLength)

            guard payloadLength <= FramedJSONCodec.maximumPayloadSize else {
                throw FramedJSONError.declaredPayloadTooLarge(payloadLength)
            }

            let frameLength = FramedJSONCodec.headerSize + payloadLength
            guard buffer.count >= frameLength else {
                break
            }

            frames.append(
                buffer.subdata(
                    in: FramedJSONCodec.headerSize ..< frameLength
                )
            )
            buffer.removeSubrange(0 ..< frameLength)
        }

        return frames
    }
}
