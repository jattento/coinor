import Foundation

/// One automation run, handed from the launchd job's shell script to the
/// already-running Coinor GUI over the `coinor://run-automation` URL scheme.
///
/// The shell script mints `runID`/`sessionID` itself (see `AutomationJob`)
/// before deciding whether Coinor's GUI is live, so both the live hand-off
/// path and the plain-`grok` fallback record the same identifiers in the run
/// log regardless of which one actually executes the automation.
struct AutomationRunRequest: Equatable, Sendable {
    var automationID: String
    var runID: String
    var sessionID: String
    var trigger: AutomationTrigger

    static let scheme = "coinor"
    static let host = "run-automation"
}

enum AutomationRunRequestRouting {
    /// The `coinor://run-automation?...` URL the launchd job opens when it
    /// finds Coinor's GUI live. `AutomationRunRequestRouting.parse` is this
    /// function's exact inverse.
    static func url(for request: AutomationRunRequest) -> URL {
        var components = URLComponents()
        components.scheme = AutomationRunRequest.scheme
        components.host = AutomationRunRequest.host
        components.queryItems = [
            URLQueryItem(name: "automationID", value: request.automationID),
            URLQueryItem(name: "runID", value: request.runID),
            URLQueryItem(name: "sessionID", value: request.sessionID),
            URLQueryItem(name: "trigger", value: request.trigger.rawValue),
        ]
        // `URLComponents` never fails to produce a URL from a fixed scheme
        // plus percent-encoded query items.
        return components.url!
    }

    /// Parses a URL Coinor received through `onOpenURL`. Returns `nil` for
    /// anything that is not a well-formed `coinor://run-automation` request,
    /// so a stray or malformed URL is silently ignored rather than crashing.
    static func parse(_ url: URL) -> AutomationRunRequest? {
        guard url.scheme == AutomationRunRequest.scheme,
              url.host == AutomationRunRequest.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        guard let automationID = value("automationID"), !automationID.isEmpty,
              let runID = value("runID"), !runID.isEmpty,
              let sessionID = value("sessionID"), !sessionID.isEmpty,
              let triggerRaw = value("trigger"),
              let trigger = AutomationTrigger(rawValue: triggerRaw)
        else {
            return nil
        }
        return AutomationRunRequest(
            automationID: automationID,
            runID: runID,
            sessionID: sessionID,
            trigger: trigger
        )
    }
}
