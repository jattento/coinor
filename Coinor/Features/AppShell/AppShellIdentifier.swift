import Foundation

/// Accessibility identifiers for the major regions of the application shell.
///
/// UI tests run in a separate process and cannot import the application module,
/// so they repeat these literals. `AppFoundationTests` pins the values so the two
/// copies cannot drift silently.
enum AppShellIdentifier {
    static let sidebar = "AppShellSidebar"
    static let pinnedSection = "AppShellSidebarPinned"
    static let projectsSection = "AppShellSidebarProjects"
    static let conversationSearchField = "AppShellConversationSearch"
    static let searchResultsSection = "AppShellSearchResults"
    static let agenticSearchPanel = "AppShellAgenticSearchPanel"
    static let agenticSearchClose = "AppShellAgenticSearchClose"
    static let searchEmptyState = "AppShellSearchEmptyState"
    static let grokUpdateButton = "AppShellGrokUpdate"
    static let terminalRegion = "AppShellTerminalRegion"
    static let telegramLiveTurn = "AppShellTelegramLiveTurn"
    static let workflowsDestination = "AppShellWorkflowsDestination"
    static let workflowCenter = "WorkflowCenter"
    static let workflowCatalogSearch = "WorkflowCatalogSearch"
    static let workflowCatalog = "WorkflowCatalog"
    static let workflowLauncher = "WorkflowLauncher"
    static let workflowRuns = "WorkflowRuns"
    static let workflowInspector = "WorkflowInspector"
    static let workflowLaunchButton = "WorkflowLaunchButton"
    static let workflowRefreshButton = "WorkflowRefreshButton"
    static let workflowBackButton = "WorkflowBackButton"
    static let startupDiagnostics = "AppShellStartupDiagnostics"
    static let refreshStartupChecks = "AppShellRefreshStartupChecks"

    static func workflowDefinition(_ name: String) -> String {
        "WorkflowDefinition.\(name)"
    }

    static func workflowRun(_ runID: String) -> String {
        "WorkflowRun.\(runID)"
    }

    static func startupCheckRow(_ kind: StartupCheck.Kind) -> String {
        "AppShellStartupCheck.\(kind.rawValue)"
    }
}
