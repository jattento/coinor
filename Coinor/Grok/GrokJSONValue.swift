import Foundation

/// A decoded JSON value.
///
/// Grok's extension payloads are contracts owned by the local fork, so every
/// typed model in Coinor keeps the value it was decoded from and reads fields
/// defensively. An additive field never breaks decoding, and a field Coinor
/// does not model yet is still reachable through the preserved value.
enum GrokJSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([GrokJSONValue])
    case object([String: GrokJSONValue])
}

extension GrokJSONValue: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([GrokJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: GrokJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

extension GrokJSONValue {
    static func decode(_ data: Data) throws -> GrokJSONValue {
        try JSONDecoder().decode(GrokJSONValue.self, from: data)
    }

    /// Encodes with sorted keys so a request's bytes depend only on its values.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    subscript(key: String) -> GrokJSONValue? {
        guard case let .object(members) = self else { return nil }
        let member = members[key]
        return member == .null ? nil : member
    }

    var isNull: Bool { self == .null }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        switch self {
        case let .int(value):
            return value
        case let .double(value):
            return Int(exactly: value.rounded())
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .int(value):
            return Double(value)
        case let .double(value):
            return value
        default:
            return nil
        }
    }

    var arrayValue: [GrokJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var objectValue: [String: GrokJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    /// The array at `key`, or an empty array when the field is absent. Grok
    /// omits empty collections rather than serializing them.
    func stringArray(_ key: String) -> [String] {
        self[key]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

extension GrokJSONValue: ExpressibleByNilLiteral {
    init(nilLiteral: ()) { self = .null }
}

extension GrokJSONValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension GrokJSONValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self = .int(value) }
}

extension GrokJSONValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) { self = .double(value) }
}

extension GrokJSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

extension GrokJSONValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: GrokJSONValue...) { self = .array(elements) }
}

extension GrokJSONValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, GrokJSONValue)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
}
