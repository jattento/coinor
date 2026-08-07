import Foundation

struct GrokForkVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let overlay: Int

    init?(text: String) {
        let pattern = #"(?<!\d)(\d+)\.(\d+)\.(\d+)(?:-overlay\.(\d+))?"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let major = Self.component(1, match: match, text: text),
              let minor = Self.component(2, match: match, text: text),
              let patch = Self.component(3, match: match, text: text) else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        overlay = Self.component(4, match: match, text: text) ?? 0
    }

    static func < (lhs: GrokForkVersion, rhs: GrokForkVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch, lhs.overlay)
            < (rhs.major, rhs.minor, rhs.patch, rhs.overlay)
    }

    private static func component(
        _ index: Int,
        match: NSTextCheckingResult,
        text: String
    ) -> Int? {
        let range = match.range(at: index)
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: text) else {
            return nil
        }
        return Int(text[swiftRange])
    }
}

struct GrokRelease: Equatable, Sendable {
    let tagName: String
    let version: GrokForkVersion
    let url: URL
}

protocol GrokUpdateChecking: Sendable {
    func availableUpdate() async throws -> GrokRelease?
}

struct GitHubGrokUpdateChecker: GrokUpdateChecking {
    private struct ReleasePayload: Decodable {
        let tagName: String
        let htmlURL: URL

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private let fetchLatestRelease: @Sendable () async throws -> Data
    private let probeInstalledVersion: @Sendable () async throws -> String

    init(
        fetchLatestRelease: @escaping @Sendable () async throws -> Data,
        probeInstalledVersion: @escaping @Sendable () async throws -> String
    ) {
        self.fetchLatestRelease = fetchLatestRelease
        self.probeInstalledVersion = probeInstalledVersion
    }

    func availableUpdate() async throws -> GrokRelease? {
        async let releaseData = fetchLatestRelease()
        async let installedText = probeInstalledVersion()
        let (data, localText) = try await (releaseData, installedText)

        let payload = try JSONDecoder().decode(
            ReleasePayload.self,
            from: data
        )
        guard let localVersion = GrokForkVersion(text: localText),
              let remoteVersion = GrokForkVersion(
                text: payload.tagName
              ) else {
            return nil
        }
        guard localVersion < remoteVersion else { return nil }
        return GrokRelease(
            tagName: payload.tagName,
            version: remoteVersion,
            url: payload.htmlURL
        )
    }

    static func live(
        session: URLSession = .shared
    ) -> GitHubGrokUpdateChecker {
        GitHubGrokUpdateChecker(
            fetchLatestRelease: {
                let url = URL(
                    string: "https://api.github.com/repos/jattento/grok-build/releases/latest"
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
            },
            probeInstalledVersion: {
                let executable = try GrokExecutable.resolve()
                let leaderSocket = try GrokLeaderSocket(
                    path: "/tmp/coinor-grok-version.sock"
                )
                return try await GrokExecutableVersionProbe().run(
                    launch: GrokControlLaunch(
                        executable: executable,
                        leaderSocket: leaderSocket
                    ),
                    timeout: .seconds(3)
                )
            }
        )
    }
}
