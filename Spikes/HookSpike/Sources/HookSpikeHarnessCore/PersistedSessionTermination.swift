import Foundation

public enum PersistedSessionTermination: Equatable {
    case cancelled
    case failed

    public static func detect(in jsonLine: Data) -> PersistedSessionTermination? {
        guard let object = try? JSONSerialization.jsonObject(with: jsonLine),
              let record = object as? [String: Any]
        else {
            return nil
        }

        if record["type"] as? String == "turn_ended",
           record["outcome"] as? String == "cancelled"
        {
            return .cancelled
        }

        guard let params = record["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "retry_state",
              update["type"] as? String == "failed"
        else {
            return nil
        }

        return .failed
    }
}
