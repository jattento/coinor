import AppKit
import SwiftUI

/// libghostty only exposes search through binding-action strings, so keeping
/// them in one place lets tests pin the exact wire format instead of trusting
/// string literals scattered across the surface view.
enum TerminalSearchAction: Equatable, Sendable {
    case start
    case selection
    case needle(String)
    case next
    case previous
    case end

    var bindingAction: String {
        switch self {
        case .start:
            "start_search"
        case .selection:
            "search_selection"
        case .needle(let text):
            // The core keeps everything after the first colon, so needles that
            // contain colons or newlines have to pass through untouched.
            "search:\(text)"
        case .next:
            "navigate_search:next"
        case .previous:
            "navigate_search:previous"
        case .end:
            "end_search"
        }
    }
}

/// A one or two character needle matches nearly every screen, so searching on
/// every keystroke spends the core's search thread on results the user is
/// about to replace. Longer needles are specific enough to run immediately.
enum TerminalSearchDebouncePolicy {
    static let shortNeedleDelay = Duration.milliseconds(300)

    static func delay(forNeedleLength length: Int) -> Duration {
        switch length {
        case 1, 2:
            shortNeedleDelay
        default:
            .zero
        }
    }
}

/// The core reports both counters as -1 when it has nothing to say, and the
/// selected index it sends is zero based while people count matches from one.
enum TerminalSearchStatus {
    static func label(
        total: Int?,
        selected: Int?,
        needleIsEmpty: Bool
    ) -> String? {
        guard !needleIsEmpty else { return nil }
        let matches = matchCount(total)
        guard matches > 0 else { return "0/0" }
        // Until the user moves to a match the core has nothing selected, and
        // claiming match zero of nine would read as a failed search.
        guard let selected, selected >= 0 else { return "\(matches)" }
        return "\(selected + 1)/\(matches)"
    }

    static func hasMatches(total: Int?) -> Bool {
        matchCount(total) > 0
    }

    private static func matchCount(_ total: Int?) -> Int {
        max(total ?? -1, 0)
    }
}

enum TerminalSearchCommand: Equatable, Sendable {
    case find
    case findNext
    case findPrevious
}

/// The embedded Ghostty configuration leaves the command-key find shortcuts
/// unbound, so AppKit has to claim them before the key reaches the core.
enum TerminalSearchShortcut {
    static func command(
        forCharacters characters: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> TerminalSearchCommand? {
        guard let key = characters?.lowercased() else { return nil }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags == [.command] {
            switch key {
            case "f":
                return .find
            case "g":
                return .findNext
            default:
                return nil
            }
        }
        if flags == [.command, .shift], key == "g" {
            return .findPrevious
        }
        return nil
    }
}

enum TerminalSearchIdentifier {
    static let field = "terminal.search.field"
    static let next = "terminal.search.next"
    static let previous = "terminal.search.previous"
    static let close = "terminal.search.close"
    static let status = "terminal.search.status"
}

/// Search state for exactly one terminal surface. Every surface owns its own
/// instance so opening the bar on one pane leaves every other pane alone.
@MainActor
final class TerminalSearchState: ObservableObject {
    @Published var needle = "" {
        didSet {
            guard needle != oldValue, !suppressesSearch else { return }
            scheduleSearch()
        }
    }

    @Published private(set) var total: Int?
    @Published private(set) var selected: Int?
    @Published private(set) var focusToken = 0

    /// Owned by the surface, which installs weak captures, so the bar never
    /// keeps its terminal alive.
    var onCommand: ((TerminalSearchAction) -> Void)?
    var onClose: (() -> Void)?

    private var debounce: Task<Void, Never>?
    private var suppressesSearch = false

    var statusLabel: String? {
        TerminalSearchStatus.label(
            total: total,
            selected: selected,
            needleIsEmpty: needle.isEmpty
        )
    }

    var hasMatches: Bool {
        TerminalSearchStatus.hasMatches(total: total)
    }

    var reportsNoMatches: Bool {
        !needle.isEmpty && !hasMatches
    }

    func seed(_ value: String) {
        guard !value.isEmpty, value != needle else { return }
        needle = value
    }

    func navigate(next: Bool) {
        onCommand?(next ? .next : .previous)
    }

    func close() {
        onClose?()
    }

    func requestFieldFocus() {
        focusToken &+= 1
    }

    func applyTotal(_ value: Int) {
        total = value
    }

    func applySelected(_ value: Int) {
        selected = value
    }

    func reset() {
        debounce?.cancel()
        debounce = nil
        suppressesSearch = true
        needle = ""
        suppressesSearch = false
        total = nil
        selected = nil
    }

    private func scheduleSearch() {
        debounce?.cancel()
        let text = needle
        let delay = TerminalSearchDebouncePolicy.delay(
            forNeedleLength: text.count
        )
        guard delay != .zero else {
            debounce = nil
            runSearch(text)
            return
        }
        debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.runSearch(text)
        }
    }

    private func runSearch(_ text: String) {
        if text.isEmpty {
            // An empty needle stops the search thread without any further
            // report, so the counters have to be cleared here.
            total = nil
            selected = nil
        }
        onCommand?(.needle(text))
    }
}

struct TerminalSearchBar: View {
    @ObservedObject var state: TerminalSearchState
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            TextField("Find", text: $state.needle)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($fieldFocused)
                .onSubmit {
                    state.navigate(next: true)
                }
                .help("Find in Terminal")
                .accessibilityLabel("Find in Terminal")
                .accessibilityIdentifier(TerminalSearchIdentifier.field)

            if let status = state.statusLabel {
                Text(status)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(state.reportsNoMatches ? .red : .secondary)
                    .help(state.reportsNoMatches ? "No Matches" : "Match Count")
                    .accessibilityLabel(
                        state.reportsNoMatches ? "No matches" : status
                    )
                    .accessibilityIdentifier(TerminalSearchIdentifier.status)
            }

            navigationButton(
                systemImage: "chevron.up",
                title: "Find Previous",
                identifier: TerminalSearchIdentifier.previous
            ) {
                state.navigate(next: false)
            }
            .keyboardShortcut(.return, modifiers: .shift)

            navigationButton(
                systemImage: "chevron.down",
                title: "Find Next",
                identifier: TerminalSearchIdentifier.next
            ) {
                state.navigate(next: true)
            }

            Button {
                state.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Close Find Bar")
            .accessibilityLabel("Close Find Bar")
            .accessibilityIdentifier(TerminalSearchIdentifier.close)
        }
        .padding(.horizontal, 8)
        .frame(width: 260, height: 30)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .onExitCommand {
            state.close()
        }
        .onAppear {
            fieldFocused = true
        }
        .onChange(of: state.focusToken) { _ in
            fieldFocused = true
        }
    }

    private func navigationButton(
        systemImage: String,
        title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .disabled(!state.hasMatches)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}
