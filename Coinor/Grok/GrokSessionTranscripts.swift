import Foundation

/// Finds the on-disk Grok chat history for each conversation.
///
/// Grok keys its session directories by URL-encoded working directory, which
/// Coinor never tracks, so a path cannot be derived from a session ID. One
/// shallow scan of the sessions root builds the whole map instead, which is
/// what lets Conan Code hand the conversation finder a path to grep rather than
/// exporting every transcript into a prompt.
struct GrokSessionTranscriptLocator: Sendable {
    static let transcriptFileName = "chat_history.jsonl"

    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// `GROK_HOME` wins when Grok has been pointed somewhere else; otherwise the
    /// standard `~/.grok/sessions`.
    static func defaultRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let grokHome: URL
        if let configured = environment["GROK_HOME"],
           configured.hasPrefix("/") {
            grokHome = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            grokHome = homeDirectory
                .appendingPathComponent(".grok", isDirectory: true)
        }
        return grokHome.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Session identifier to absolute transcript path, for every session that
    /// has a readable chat history. Sessions without one are simply absent; the
    /// finder then matches them on title alone.
    func transcriptPaths(
        fileManager: FileManager = .default
    ) -> [String: String] {
        guard let workingDirectories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var result: [String: String] = [:]
        for workingDirectory in workingDirectories {
            guard let sessions = try? fileManager.contentsOfDirectory(
                at: workingDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for session in sessions {
                let transcript = session.appendingPathComponent(
                    Self.transcriptFileName,
                    isDirectory: false
                )
                guard fileManager.isReadableFile(atPath: transcript.path) else {
                    continue
                }
                result[session.lastPathComponent] = transcript.path
            }
        }
        return result
    }
}
