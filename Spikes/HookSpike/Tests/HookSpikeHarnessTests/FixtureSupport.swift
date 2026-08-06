import Foundation
import Testing

enum Fixture {
    static let root = "00000000-0000-7000-8000-000000000001"
    static let child = "00000000-0000-7000-8000-000000000002"
    static let grandchild = "00000000-0000-7000-8000-000000000003"
    static let external = "00000000-0000-7000-8000-000000000999"

    static func data(_ name: String, extension fileExtension: String = "json") throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: fileExtension
            )
        )
        return try Data(contentsOf: url)
    }

    static func replacing(
        _ data: Data,
        sessionID: String? = nil,
        subagentID: String? = nil,
        timestamp: String? = nil
    ) throws -> Data {
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        if let sessionID {
            object["sessionId"] = sessionID
        }
        if let subagentID {
            object["subagentId"] = subagentID
        }
        if let timestamp {
            object["timestamp"] = timestamp
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
