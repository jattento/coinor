import Foundation

/// How far the `jattento/grok-build` fork's `main` branch trails the
/// original `xai-org/grok-build` repository's `main` branch.
///
/// Distinct from ``GrokUpdateChecking``, which compares the locally
/// installed build against the fork's own latest release. This signal is
/// about commits the fork has not yet absorbed from upstream at all.
struct GrokUpstreamSyncStatus: Equatable, Sendable {
    /// Number of upstream commits the fork's `main` is missing.
    let missingCommitCount: Int
    /// GitHub compare view for the missing commits.
    let url: URL
}

protocol GrokUpstreamSyncChecking: Sendable {
    /// Returns the sync status when the fork is missing one or more
    /// upstream commits, or `nil` when the fork is fully caught up.
    func missingUpstreamCommits() async throws -> GrokUpstreamSyncStatus?
}

/// Checks `jattento/grok-build` against `xai-org/grok-build` via GitHub's
/// compare API, so it never needs a local git checkout of either repo.
struct GitHubGrokUpstreamSyncChecker: GrokUpstreamSyncChecking {
    private struct ComparePayload: Decodable {
        let aheadBy: Int
        let htmlURL: URL

        private enum CodingKeys: String, CodingKey {
            case aheadBy = "ahead_by"
            case htmlURL = "html_url"
        }
    }

    private let fetchCompare: @Sendable () async throws -> Data

    init(fetchCompare: @escaping @Sendable () async throws -> Data) {
        self.fetchCompare = fetchCompare
    }

    func missingUpstreamCommits() async throws -> GrokUpstreamSyncStatus? {
        let data = try await fetchCompare()
        let payload = try JSONDecoder().decode(ComparePayload.self, from: data)
        guard payload.aheadBy > 0 else { return nil }
        return GrokUpstreamSyncStatus(
            missingCommitCount: payload.aheadBy,
            url: payload.htmlURL
        )
    }

    static func live(session: URLSession = .shared) -> GitHubGrokUpstreamSyncChecker {
        GitHubGrokUpstreamSyncChecker(fetchCompare: {
            let url = URL(
                string: "https://api.github.com/repos/jattento/grok-build/compare/main...xai-org:main"
            )!
            var request = URLRequest(url: url)
            request.setValue(
                "application/vnd.github+json",
                forHTTPHeaderField: "Accept"
            )
            request.setValue(
                "Coinor",
                forHTTPHeaderField: "User-Agent"
            )
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return data
        })
    }
}
