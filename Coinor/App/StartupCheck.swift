import Foundation

/// One startup compatibility check reported by the application shell.
///
/// The shell renders whatever the injected provider returns, so later phases can
/// replace the probe implementation without touching the views.
struct StartupCheck: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case grokExecutable
        case ghosttyRuntime
        case hookRegistration
        case leaderSocket

        var title: String {
            switch self {
            case .grokExecutable:
                return "Grok Executable"
            case .ghosttyRuntime:
                return "Ghostty Runtime"
            case .hookRegistration:
                return "Hook Registration"
            case .leaderSocket:
                return "Leader Socket"
            }
        }
    }

    enum Status: String, Sendable {
        case pending
        case passed
        case warning
        case failed

        var label: String {
            switch self {
            case .pending:
                return "Pending"
            case .passed:
                return "Passed"
            case .warning:
                return "Warning"
            case .failed:
                return "Failed"
            }
        }
    }

    let kind: Kind
    var status: Status
    var detail: String

    var id: Kind { kind }

    static func pending(_ kind: Kind) -> StartupCheck {
        StartupCheck(kind: kind, status: .pending, detail: "Not checked yet")
    }

    static var allPending: [StartupCheck] {
        Kind.allCases.map(StartupCheck.pending)
    }
}

/// Supplies the startup checks shown by the application shell.
protocol StartupDiagnosticsProviding: Sendable {
    func runStartupChecks() async -> [StartupCheck]
}
