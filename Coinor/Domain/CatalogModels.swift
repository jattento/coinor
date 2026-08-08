import Foundation

/// The minimal facts about a Grok session Coinor needs to place it in the
/// sidebar catalog. Everything here is Grok-owned and passed through
/// untouched; Coinor never persists it.
struct SessionSummary: Equatable, Identifiable, Sendable {
    let id: String
    let projectID: String
    let title: String
    let lastActivityAt: Date?

    init(
        id: String,
        projectID: String,
        title: String,
        lastActivityAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.lastActivityAt = lastActivityAt
    }
}

/// A conversation row ready for display. Pin and archive state are expressed
/// by which section of `SessionCatalog` the row appears in, not by fields on
/// the row itself.
struct ConversationRow: Equatable, Identifiable, Sendable {
    let session: SessionSummary

    var id: String { session.id }
}

/// A project and its flat, unpinned, unarchived conversations. Conversations
/// stay flat regardless of whether they came from the main checkout or a
/// worktree; worktree identity is resolved into `projectID` upstream.
struct ProjectRow: Equatable, Identifiable, Sendable {
    let projectID: String
    let conversations: [ConversationRow]
    let isManuallyRegistered: Bool
    let isExpanded: Bool

    var id: String { projectID }
}

/// The sidebar's full read model: pinned conversations above every visible
/// project.
struct SessionCatalog: Equatable, Sendable {
    let pinned: [ConversationRow]
    let projects: [ProjectRow]

    static let empty = SessionCatalog(pinned: [], projects: [])
}

extension SessionCatalog {
    /// Joins Grok's session facts with Coinor's metadata by session ID.
    ///
    /// Rules applied here: pinned sessions are excluded from their project's
    /// row; archived sessions and archived projects are excluded entirely;
    /// a manually registered project is retained even with zero visible
    /// conversations; metadata entries that reference an ID absent from
    /// `sessions` are ignored rather than surfaced or treated as an error.
    static func build(sessions: [SessionSummary], metadata: MetadataDocument) -> SessionCatalog {
        let sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func isVisible(_ session: SessionSummary) -> Bool {
            !metadata.isSessionArchived(session.id) && !metadata.isProjectArchived(session.projectID)
        }

        let pinned: [ConversationRow] = metadata.pinnedSessionIDs.compactMap { sessionID in
            guard let session = sessionsByID[sessionID], isVisible(session) else { return nil }
            return ConversationRow(session: session)
        }
        let pinnedIDs = Set(pinned.map(\.id))

        var sessionsByProject: [String: [SessionSummary]] = [:]
        var projectOrder: [String] = []
        var discoveredProjects: Set<String> = []
        for session in sessions
        where !metadata.isProjectArchived(session.projectID) {
            if discoveredProjects.insert(session.projectID).inserted {
                projectOrder.append(session.projectID)
            }
            sessionsByProject[session.projectID, default: []].append(session)
        }

        let manualOnlyProjectIDs = metadata.projects
            .filter { entry in
                entry.value.manuallyRegistered
                    && !entry.value.archived
                    && !discoveredProjects.contains(entry.key)
            }
            .map(\.key)
            .sorted()

        let defaultProjectOrder = projectOrder + manualOnlyProjectIDs
        let availableProjectIDs = Set(defaultProjectOrder)
        var seenProjectIDs: Set<String> = []
        let storedProjectOrder = metadata.projectOrder.filter {
            availableProjectIDs.contains($0)
                && seenProjectIDs.insert($0).inserted
        }
        let remainingProjectIDs = defaultProjectOrder.filter {
            !seenProjectIDs.contains($0)
        }

        let projectRows = (storedProjectOrder + remainingProjectIDs).map { projectID in
            let projectSessions = sessionsByProject[projectID] ?? []
            let sessionsByID = Dictionary(
                projectSessions.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let defaultConversationOrder = projectSessions.map(\.id)
            let availableSessionIDs = Set(defaultConversationOrder)
            var seenSessionIDs: Set<String> = []
            let storedConversationOrder = metadata
                .projectConversationOrder(projectID)
                .filter {
                    availableSessionIDs.contains($0)
                        && seenSessionIDs.insert($0).inserted
                }
            let remainingSessionIDs = defaultConversationOrder.filter {
                !seenSessionIDs.contains($0)
            }
            let conversations = (
                storedConversationOrder + remainingSessionIDs
            ).compactMap { sessionID -> ConversationRow? in
                guard let session = sessionsByID[sessionID],
                      isVisible(session),
                      !pinnedIDs.contains(sessionID) else {
                    return nil
                }
                return ConversationRow(session: session)
            }

            return ProjectRow(
                projectID: projectID,
                conversations: conversations,
                isManuallyRegistered: metadata.isProjectManuallyRegistered(projectID),
                isExpanded: metadata.isProjectExpanded(projectID)
            )
        }

        return SessionCatalog(pinned: pinned, projects: projectRows)
    }
}

enum ConversationSearch {
    private struct Rank: Equatable {
        let tier: Int
        let quality: Int
    }

    private struct RankedConversation {
        let row: ConversationRow
        let rank: Rank
    }

    static func hasEffectiveQuery(_ query: String) -> Bool {
        !normalize(query).isEmpty
    }

    static func results(
        query: String,
        sessions: [SessionSummary],
        metadata: MetadataDocument
    ) -> [ConversationRow] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }

        let ranked: [RankedConversation] = sessions.compactMap { session in
            guard !metadata.isSessionArchived(session.id),
                  !metadata.isProjectArchived(session.projectID),
                  let rank = rank(
                    normalizedQuery: normalizedQuery,
                    title: session.title
                  ) else {
                return nil
            }
            return RankedConversation(
                row: ConversationRow(session: session),
                rank: rank
            )
        }

        return ranked.sorted { lhs, rhs in
            if lhs.rank.tier != rhs.rank.tier {
                return lhs.rank.tier > rhs.rank.tier
            }
            if lhs.rank.quality != rhs.rank.quality {
                return lhs.rank.quality > rhs.rank.quality
            }
            let lhsDate = lhs.row.session.lastActivityAt ?? .distantPast
            let rhsDate = rhs.row.session.lastActivityAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            let titleOrder = lhs.row.session.title
                .localizedCaseInsensitiveCompare(rhs.row.session.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.row.id < rhs.row.id
        }
        .map(\.row)
    }

    private static func rank(
        normalizedQuery: String,
        title: String
    ) -> Rank? {
        let normalizedTitle = normalize(title)
        guard !normalizedTitle.isEmpty else { return nil }

        if normalizedTitle == normalizedQuery {
            return Rank(tier: 5, quality: 0)
        }
        if normalizedTitle.hasPrefix(normalizedQuery) {
            return Rank(
                tier: 4,
                quality: -max(
                    0,
                    normalizedTitle.count - normalizedQuery.count
                )
            )
        }
        if let range = normalizedTitle.range(of: normalizedQuery) {
            let offset = normalizedTitle.distance(
                from: normalizedTitle.startIndex,
                to: range.lowerBound
            )
            return Rank(
                tier: 3,
                quality: -(
                    offset * 10
                        + max(
                            0,
                            normalizedTitle.count - normalizedQuery.count
                        )
                )
            )
        }

        let queryTokens = normalizedQuery.split(separator: " ")
        let titleTokens = normalizedTitle.split(separator: " ")
        if let quality = tokenQuality(
            queryTokens: queryTokens,
            titleTokens: titleTokens
        ) {
            return Rank(tier: 2, quality: quality)
        }

        let compactQuery = normalizedQuery.replacingOccurrences(
            of: " ",
            with: ""
        )
        let compactTitle = normalizedTitle.replacingOccurrences(
            of: " ",
            with: ""
        )
        guard let subsequence = subsequenceScore(
            query: compactQuery,
            title: compactTitle
        ) else {
            return nil
        }
        return Rank(tier: 1, quality: subsequence)
    }

    private static func tokenQuality(
        queryTokens: [Substring],
        titleTokens: [Substring]
    ) -> Int? {
        guard !queryTokens.isEmpty else { return nil }

        var best: Int?
        for start in titleTokens.indices
        where titleTokens[start].hasPrefix(queryTokens[0]) {
            var matchedIndices = [start]
            var nextTitleIndex = titleTokens.index(after: start)

            for queryToken in queryTokens.dropFirst() {
                guard let match = titleTokens[nextTitleIndex...]
                    .firstIndex(where: { $0.hasPrefix(queryToken) }) else {
                    matchedIndices.removeAll()
                    break
                }
                matchedIndices.append(match)
                nextTitleIndex = titleTokens.index(after: match)
            }

            guard matchedIndices.count == queryTokens.count,
                  let last = matchedIndices.last else {
                continue
            }
            let exactMatches = zip(queryTokens, matchedIndices).filter {
                titleTokens[$0.1] == $0.0
            }.count
            let span = last - start
            let gaps = span - max(0, queryTokens.count - 1)
            let quality = exactMatches * 100
                - gaps * 20
                - start * 5
            best = max(best ?? quality, quality)
        }
        return best
    }

    private static func subsequenceScore(
        query: String,
        title: String
    ) -> Int? {
        let queryCharacters = Array(query)
        let titleCharacters = Array(title)
        guard !queryCharacters.isEmpty else { return nil }

        var best: Int?
        for start in titleCharacters.indices
        where titleCharacters[start] == queryCharacters[0] {
            var queryIndex = 1
            var titleIndex = start + 1
            while queryIndex < queryCharacters.count,
                  titleIndex < titleCharacters.count {
                if titleCharacters[titleIndex] == queryCharacters[queryIndex] {
                    queryIndex += 1
                }
                titleIndex += 1
            }

            guard queryIndex == queryCharacters.count else { continue }
            let end = titleIndex - 1
            let span = end - start + 1
            let gaps = span - queryCharacters.count
            let quality = -(
                start * 15
                    + gaps * 25
                    + max(0, titleCharacters.count - span)
            )
            best = max(best ?? quality, quality)
        }
        return best
    }

    private static func normalize(_ value: String) -> String {
        let folded = value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            .lowercased()
        let separated = folded.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                ? String(scalar)
                : " "
        }.joined()
        return separated
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
