import Foundation

/// Runs the compatibility contract against a remote computer.
///
/// This is the remote counterpart of the local start-up checks: resolve the
/// Grok executable, record its version, and prepare the runtime socket. It is
/// one SSH round trip, because every extra round trip is felt when adding a
/// host over a slow link.
struct RemoteHostProbe: Sendable {
    static let leaderSocketName = "grok-leader-remote.sock"

    private let runner: any RemoteCommandRunning
    private let alias: RemoteHostAlias
    private let grokRelativePath: String

    init(
        runner: any RemoteCommandRunning,
        alias: RemoteHostAlias,
        grokRelativePath: String = "bin/grok"
    ) {
        self.runner = runner
        self.alias = alias
        self.grokRelativePath = grokRelativePath
    }

    /// - Parameter localVersion: the version of this computer's Grok build.
    ///   The base version must match, because Conan Code's ACP extension
    ///   methods are contracts of that fork version. A differing overlay build
    ///   only warns.
    func probe(localVersion: GrokForkVersion) throws -> RemoteHost {
        let script = Self.script(grokRelativePath: grokRelativePath)
        let result = try runner.run(remoteCommand: script, timeout: .seconds(30))
        guard result.succeeded else {
            throw RemoteHostError.unreachable(
                alias: alias.rawValue,
                detail: Self.failureDetail(result)
            )
        }

        let fields = Self.fields(in: result.standardOutput)
        guard let home = fields["home"], !home.isEmpty else {
            throw RemoteHostError.unreachable(
                alias: alias.rawValue,
                detail: "the host did not report a home directory"
            )
        }
        let grokPath = fields["grok"] ?? ""
        guard fields["grok_executable"] == "yes", !grokPath.isEmpty else {
            throw RemoteHostError.grokNotFound(
                alias: alias.rawValue,
                path: grokPath.isEmpty
                    ? "\(home)/\(grokRelativePath)"
                    : grokPath
            )
        }
        let versionText = fields["version"] ?? ""
        guard let remoteVersion = GrokForkVersion(text: versionText) else {
            throw RemoteHostError.unreachable(
                alias: alias.rawValue,
                detail: "`grok --version` returned \"\(versionText)\""
            )
        }
        guard remoteVersion.major == localVersion.major,
              remoteVersion.minor == localVersion.minor,
              remoteVersion.patch == localVersion.patch
        else {
            throw RemoteHostError.versionMismatch(
                alias: alias.rawValue,
                remote: Self.describe(remoteVersion),
                local: Self.describe(localVersion)
            )
        }
        let versionWarning: String? = remoteVersion.overlay
            == localVersion.overlay
            ? nil
            : "\(alias.rawValue) runs Grok "
                + "\(Self.describe(remoteVersion)) and this computer runs "
                + "\(Self.describe(localVersion))."
        guard let socket = fields["socket"], !socket.isEmpty else {
            throw RemoteHostError.leaderUnavailable(
                alias: alias.rawValue,
                detail: "the runtime directory could not be created"
            )
        }
        guard socket.utf8.count <= GrokLeaderSocket.maximumPathLength else {
            throw RemoteHostError.leaderUnavailable(
                alias: alias.rawValue,
                detail: "\(socket) is longer than "
                    + "\(GrokLeaderSocket.maximumPathLength) bytes"
            )
        }

        return RemoteHost(
            alias: alias,
            grokExecutablePath: grokPath,
            grokVersion: Self.describe(remoteVersion),
            leaderSocketPath: socket,
            homeDirectory: home,
            maximumSessions: fields["max_sessions"].flatMap(Int.init),
            versionWarning: versionWarning
        )
    }

    /// One script, one round trip. Every value is printed as `key=value` so a
    /// noisy login shell cannot be mistaken for output.
    static func script(grokRelativePath: String) -> String {
        let quotedRelative = ShellQuoting.quote(grokRelativePath)
        let quotedSocketName = ShellQuoting.quote(leaderSocketName)
        return """
        set -u
        grok="$HOME"/\(quotedRelative)
        runtime="$HOME/Library/Application Support/Coinor"
        mkdir -p "$runtime" || exit 3
        printf 'coinor.home=%s\\n' "$HOME"
        printf 'coinor.grok=%s\\n' "$grok"
        if [ -x "$grok" ]; then
            printf 'coinor.grok_executable=%s\\n' yes
            printf 'coinor.version=%s\\n' "$("$grok" --version 2>&1 | head -n 1)"
        else
            printf 'coinor.grok_executable=%s\\n' no
        fi
        printf 'coinor.socket=%s/%s\\n' "$runtime" \(quotedSocketName)
        sessions=$(awk '/^[[:space:]]*MaxSessions[[:space:]]/ {print $2}' \
            /etc/ssh/sshd_config 2>/dev/null | tail -n 1)
        if [ -n "${sessions:-}" ]; then
            printf 'coinor.max_sessions=%s\\n' "$sessions"
        fi
        """
    }

    static func fields(in output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("coinor."),
                  let separator = line.firstIndex(of: "=")
            else {
                continue
            }
            let key = String(line[line.index(line.startIndex, offsetBy: 7)..<separator])
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        return values
    }

    static func describe(_ version: GrokForkVersion) -> String {
        let base = "\(version.major).\(version.minor).\(version.patch)"
        return version.overlay == 0 ? base : base + "-overlay.\(version.overlay)"
    }

    private static func failureDetail(_ result: RemoteCommandResult) -> String {
        let detail = result.standardError
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty
            ? "ssh exited with status \(result.terminationStatus)"
            : detail
    }
}
