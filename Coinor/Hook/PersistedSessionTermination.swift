import Foundation

enum PersistedSessionTermination: Equatable, Sendable {
    case cancelled
    case failed

    static func detect(in jsonLine: Data) -> PersistedSessionTermination? {
        guard let value = try? GrokJSONValue.decode(jsonLine) else { return nil }
        return detect(in: value)
    }

    static func detect(
        in record: GrokJSONValue
    ) -> PersistedSessionTermination? {
        if record["type"]?.stringValue == "turn_ended",
           record["outcome"]?.stringValue == "cancelled" {
            return .cancelled
        }

        let update = record["params"]?["update"] ?? record["update"]
        if update?["sessionUpdate"]?.stringValue == "turn_ended",
           update?["outcome"]?.stringValue == "cancelled" {
            return .cancelled
        }
        if update?["sessionUpdate"]?.stringValue == "retry_state",
           update?["type"]?.stringValue == "failed" {
            return .failed
        }
        return nil
    }
}
