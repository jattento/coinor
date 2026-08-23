import Foundation

/// One published fork release in the changelog, summarized as the user-facing
/// changes it contains.
struct GrokReleaseEntry: Identifiable, Equatable, Sendable, Decodable {
    /// Release tag, e.g. `v1.0.3-overlay.5`.
    let tag: String
    /// Human-readable date the release was published.
    let publishedAt: String
    /// The features and fixes this release contains from the fork's own
    /// development, extracted from the release notes. Validation and security
    /// boilerplate (test counts, gitleaks, codesign) is filtered out.
    let forkSummary: [String]
    /// The features and fixes this release pulled in from the upstream
    /// `xai-org/grok-build` repository, extracted from the commit bodies of
    /// the `Synced from monorepo` commits it contains. The list can be long
    /// because each upstream snapshot rolls up many changes.
    let upstreamSummary: [String]

    var id: String { tag }
}

/// Loads the Grok fork changelog.
///
/// The changelog is cooked into the application bundle at release time by
/// `scripts/grok-changelog/cook.sh`, so it is available instantly and without
/// network access. The cooked file lives at
/// `Coinor/Resources/GrokChangelog.json`.
protocol GrokChangelogLoading: Sendable {
    /// Published fork releases, newest first.
    func load() async throws -> [GrokReleaseEntry]
}

/// Reads the cooked changelog from the application bundle.
struct BundledGrokChangelogLoader: GrokChangelogLoading {
    /// The cooked changelog is committed to the repository and shipped inside
    /// the application bundle, so no network access is required.
    static let resourceName = "GrokChangelog"

    private let resourceURL: URL?

    init(resourceURL: URL? = Bundle.main.url(
        forResource: BundledGrokChangelogLoader.resourceName,
        withExtension: "json"
    )) {
        self.resourceURL = resourceURL
    }

    func load() async throws -> [GrokReleaseEntry] {
        guard let resourceURL else {
            throw URLError(.fileDoesNotExist)
        }
        let data = try Data(contentsOf: resourceURL)
        let payload = try JSONDecoder().decode(
            ChangelogPayload.self,
            from: data
        )
        return payload.releases
    }
}

// MARK: - Cooking helpers (used by scripts/grok-changelog/cook.py)

/// The shape of the cooked changelog file.
struct ChangelogPayload: Decodable {
    let releases: [GrokReleaseEntry]
}

/// Fetches the fork releases and their commits from GitHub and reduces each
/// release to its features and fixes. This type is used by the cooking script
/// and its tests; the application reads the cooked result from the bundle.
struct GitHubGrokChangelogLoader {
    struct ReleasePayload: Decodable {
        let tagName: String
        let publishedAt: String
        let body: String?

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case publishedAt = "published_at"
            case body
        }
    }

    struct ComparePayload: Decodable {
        let totalCommits: Int
        let commits: [CommitPayload]?

        private enum CodingKeys: String, CodingKey {
            case totalCommits = "total_commits"
            case commits
        }
    }

    struct CommitPayload: Decodable {
        let sha: String
        let commit: MessagePayload

        private enum CodingKeys: String, CodingKey {
            case sha
            case commit
        }
    }

    struct MessagePayload: Decodable {
        let message: String
        let author: AuthorPayload

        private enum CodingKeys: String, CodingKey {
            case message
            case author
        }
    }

    struct AuthorPayload: Decodable {
        let name: String

        private enum CodingKeys: String, CodingKey {
            case name
        }
    }

    /// The features and fixes from the fork's release notes, keeping only the
    /// bullet-list content and dropping the validation, security, and
    /// release-mechanics sections. When the release notes have no bullets,
    /// the first non-heading paragraph is returned as the summary.
    static func forkSummary(notes: String) -> [String] {
        let boilerplateHeadings: [String] = [
            "validation", "verification", "security", "commit", "install",
        ]
        let lines = notes.components(separatedBy: .newlines)
        var bullets: [String] = []
        var paragraphs: [String] = []
        var skippingSection = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lowercased = trimmed.lowercased()

            if trimmed.hasPrefix("#") {
                // A heading toggles skipping: a boilerplate heading starts the
                // skip, any other heading ends it.
                let heading = lowercased.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                skippingSection = boilerplateHeadings.contains {
                    heading.hasPrefix($0)
                }
                continue
            }
            if skippingSection { continue }
            if trimmed.hasPrefix("- ") {
                bullets.append(
                    String(trimmed.dropFirst(2))
                        .trimmingCharacters(in: .whitespaces)
                )
            } else if !trimmed.isEmpty {
                paragraphs.append(trimmed)
            }
        }
        if bullets.isEmpty, let first = paragraphs.first {
            return [first]
        }
        return bullets
    }

    /// The features and fixes from the bodies of the `Synced from monorepo`
    /// commits, whose `Changes:` bullet list names what xAI changed. Each
    /// element is the commit's author name and its full commit message.
    static func upstreamSummary(
        commits: [(author: String, message: String)]
    ) -> [String] {
        var bullets: [String] = []
        for commit in commits where isUpstream(commit.author) {
            for line in commit.message.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    bullets.append(
                        String(trimmed.dropFirst(2))
                            .trimmingCharacters(in: .whitespaces)
                    )
                }
            }
        }
        return bullets
    }

    /// Whether a commit came from upstream (`xai-org/grok-build`), identified
    /// by the syncing bot author.
    static func isUpstream(_ author: String) -> Bool {
        author.lowercased().contains("grokkybara")
    }
}