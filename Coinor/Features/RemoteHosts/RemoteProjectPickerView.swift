import Foundation
import SwiftUI

struct RemoteProjectPickerView: View {
    @ObservedObject var coordinator: AppCoordinator
    let alias: RemoteHostAlias

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [RemoteRepositoryCandidate] = []
    @State private var selectedPath: String?
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var showsBrowser = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Remote Project")
                        .font(.headline)
                    Text(alias.rawValue)
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .disabled(isAdding)
                .help("Close")
            }
            .padding(14)

            Divider()

            searchField

            Group {
                if isLoading {
                    ProgressView("Finding repositories on \(alias.rawValue)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredCandidates.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.secondary)
                        Text(emptyTitle)
                            .font(.headline)
                        Text(emptyMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(28)
                } else {
                    List(
                        filteredCandidates,
                        id: \.path,
                        selection: $selectedPath
                    ) { candidate in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.name)
                                .font(.system(size: 13, weight: .light))
                            Text(candidate.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 3)
                        .tag(candidate.path)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("Browse…") {
                        showsBrowser = true
                    }
                    .disabled(isAdding)

                    if !isLoading {
                        Button {
                            Task { await loadCandidates() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(isAdding)
                    }

                    Spacer()

                    if isAdding {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .disabled(isAdding)
                    Button("Add Project") {
                        addSelectedProject()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedPath == nil || isLoading || isAdding)
                }
            }
            .padding(14)
        }
        .frame(minWidth: 620, minHeight: 500)
        .task {
            await loadCandidates()
        }
        .sheet(isPresented: $showsBrowser) {
            RemoteDirectoryBrowserView(
                coordinator: coordinator,
                alias: alias,
                didAddProject: {
                    showsBrowser = false
                    dismiss()
                }
            )
        }
    }

    private var filteredCandidates: [RemoteRepositoryCandidate] {
        RemoteRepositoryCandidateFilter.filtered(
            candidates,
            query: searchText
        )
    }

    private var emptyTitle: String {
        RemoteRepositoryCandidateFilter.hasEffectiveQuery(searchText)
            ? "No Matching Repositories"
            : "No Repositories Found"
    }

    private var emptyMessage: String {
        RemoteRepositoryCandidateFilter.hasEffectiveQuery(searchText)
            ? "Try a different repository name or path, or browse the remote computer."
            : "Conan Code did not find a repository automatically. Browse the remote computer to choose one."
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter repositories", text: $searchText)
                .textFieldStyle(.plain)
                .onExitCommand {
                    searchText = ""
                }
            if RemoteRepositoryCandidateFilter.hasEffectiveQuery(searchText) {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Filter")
                .accessibilityLabel("Clear Filter")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor).opacity(0.8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func loadCandidates() async {
        isLoading = true
        errorMessage = nil
        do {
            candidates = try await coordinator.remoteRepositoryCandidates(alias)
            if let selectedPath,
               !candidates.contains(where: { $0.path == selectedPath }) {
                self.selectedPath = nil
            }
        } catch {
            candidates = []
            selectedPath = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func addSelectedProject() {
        guard let selectedPath else { return }
        isAdding = true
        errorMessage = nil
        Task {
            let failure = await coordinator.addRemoteProject(
                alias: alias,
                path: selectedPath
            )
            isAdding = false
            if let failure {
                errorMessage = failure
            } else {
                dismiss()
            }
        }
    }
}

private struct RemoteDirectoryBrowserView: View {
    @ObservedObject var coordinator: AppCoordinator
    let alias: RemoteHostAlias
    let didAddProject: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath: String?
    @State private var entries: [RemoteDirectoryEntry] = []
    @State private var pathHistory: [String] = []
    @State private var selectedRepositoryPath: String?
    @State private var isLoading = true
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Browse \(alias.rawValue)")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .disabled(isAdding)
                .help("Close")
            }
            .padding(14)

            Divider()

            HStack(spacing: 8) {
                Button {
                    navigateBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(pathHistory.isEmpty || isLoading || isAdding)
                .help("Back")

                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(currentPath ?? "Loading…")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            Divider()

            Group {
                if isLoading {
                    ProgressView("Loading directory…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    Text("No subdirectories")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(entries) { entry in
                            directoryRow(entry)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text("Repositories are marked with a checkmark.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isAdding {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .disabled(isAdding)
                    Button("Add Project") {
                        addSelectedProject()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedRepositoryPath == nil || isAdding)
                }
            }
            .padding(14)
        }
        .frame(minWidth: 600, minHeight: 480)
        .task {
            await loadDirectory(nil)
        }
    }

    private func directoryRow(_ entry: RemoteDirectoryEntry) -> some View {
        HStack(spacing: 8) {
            Button {
                if entry.isRepository {
                    selectedRepositoryPath = entry.path
                } else {
                    enterDirectory(entry.path)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: entry.isRepository ? "folder.fill" : "folder")
                        .foregroundStyle(.secondary)
                    Text(entry.name)
                        .font(.system(size: 13, weight: .light))
                    if entry.isRepository {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color(nsColor: .systemGreen))
                            .accessibilityLabel("Repository")
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                enterDirectory(entry.path)
            } label: {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isLoading || isAdding)
            .help("Open \(entry.name)")
            .accessibilityLabel("Open \(entry.name)")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 5)
        .background {
            if selectedRepositoryPath == entry.path {
                RoundedRectangle(cornerRadius: 5)
                    .fill(
                        Color(nsColor: .selectedContentBackgroundColor)
                            .opacity(0.22)
                    )
            }
        }
    }

    private func enterDirectory(_ path: String) {
        guard !isLoading, !isAdding else { return }
        let previousPath = currentPath
        Task {
            let loaded = await loadDirectory(path)
            if loaded, let previousPath {
                pathHistory.append(previousPath)
            }
        }
    }

    private func navigateBack() {
        guard let path = pathHistory.last,
              !isLoading,
              !isAdding else {
            return
        }
        Task {
            let loaded = await loadDirectory(path)
            if loaded {
                pathHistory.removeLast()
            }
        }
    }

    @discardableResult
    private func loadDirectory(_ path: String?) async -> Bool {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await coordinator.remoteDirectoryEntries(
                alias,
                at: path
            )
            currentPath = result.path
            entries = result.entries
            selectedRepositoryPath = nil
            isLoading = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            return false
        }
    }

    private func addSelectedProject() {
        guard let selectedRepositoryPath else { return }
        isAdding = true
        errorMessage = nil
        Task {
            let failure = await coordinator.addRemoteProject(
                alias: alias,
                path: selectedRepositoryPath
            )
            isAdding = false
            if let failure {
                errorMessage = failure
            } else {
                didAddProject()
            }
        }
    }
}

enum RemoteRepositoryCandidateFilter {
    private struct RankedCandidate {
        let candidate: RemoteRepositoryCandidate
        let tier: Int
        let quality: Int
        let originalIndex: Int
    }

    static func hasEffectiveQuery(_ query: String) -> Bool {
        !normalized(query).isEmpty
    }

    static func filtered(
        _ candidates: [RemoteRepositoryCandidate],
        query: String
    ) -> [RemoteRepositoryCandidate] {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return candidates }

        return candidates.enumerated()
            .compactMap { index, candidate in
                rank(
                    candidate,
                    query: normalizedQuery,
                    originalIndex: index
                )
            }
            .sorted { left, right in
                if left.tier != right.tier {
                    return left.tier > right.tier
                }
                if left.quality != right.quality {
                    return left.quality > right.quality
                }
                return left.originalIndex < right.originalIndex
            }
            .map(\.candidate)
    }

    private static func rank(
        _ candidate: RemoteRepositoryCandidate,
        query: String,
        originalIndex: Int
    ) -> RankedCandidate? {
        let name = normalized(candidate.name)
        let path = normalized(candidate.path)

        if name == query {
            return RankedCandidate(
                candidate: candidate,
                tier: 5,
                quality: 0,
                originalIndex: originalIndex
            )
        }
        if name.hasPrefix(query) {
            return RankedCandidate(
                candidate: candidate,
                tier: 4,
                quality: -(name.count - query.count),
                originalIndex: originalIndex
            )
        }
        if let range = name.range(of: query) {
            return RankedCandidate(
                candidate: candidate,
                tier: 3,
                quality: -name.distance(
                    from: name.startIndex,
                    to: range.lowerBound
                ),
                originalIndex: originalIndex
            )
        }

        let queryTokens = query.split(separator: " ").map(String.init)
        let candidateTokens = (name + " " + path)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        if queryTokens.allSatisfy({ queryToken in
            candidateTokens.contains { $0.hasPrefix(queryToken) }
        }) {
            return RankedCandidate(
                candidate: candidate,
                tier: 2,
                quality: -max(0, candidateTokens.count - queryTokens.count),
                originalIndex: originalIndex
            )
        }

        let compactQuery = query.filter { !$0.isWhitespace }
        let compactCandidate = (name + path).filter { $0.isLetter || $0.isNumber }
        guard let score = subsequenceScore(
            query: compactQuery,
            candidate: compactCandidate
        ) else {
            return nil
        }
        return RankedCandidate(
            candidate: candidate,
            tier: 1,
            quality: -score,
            originalIndex: originalIndex
        )
    }

    private static func subsequenceScore(
        query: String,
        candidate: String
    ) -> Int? {
        guard !query.isEmpty else { return nil }
        var candidateIndex = candidate.startIndex
        var previousMatch: String.Index?
        var score = 0

        for character in query {
            guard let match = candidate[candidateIndex...]
                .firstIndex(of: character) else {
                return nil
            }
            if let previousMatch {
                score += candidate.distance(
                    from: previousMatch,
                    to: match
                ) - 1
            } else {
                score += candidate.distance(
                    from: candidate.startIndex,
                    to: match
                )
            }
            candidateIndex = candidate.index(after: match)
        }
        return score
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}
