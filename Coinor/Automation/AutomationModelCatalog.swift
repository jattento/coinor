import Foundation

/// One model an automation can be pinned to.
struct GrokModelOption: Identifiable, Equatable, Sendable {
    let id: String
    /// Whether Grok reports this as its configured default.
    let isDefault: Bool
}

/// Discovers the models `grok` offers, so an automation can pin one.
///
/// Grok owns the model list; Conan Code never hard-codes it, because the
/// available models change with the user's account and Grok build.
enum AutomationModelCatalog {
    /// Parses the output of `grok models`.
    ///
    /// The command prints one model per line as `  - name`, marking the
    /// default with `*` and a trailing `(default)`.
    static func parse(_ output: String) -> [GrokModelOption] {
        var options: [GrokModelOption] = []
        var seen: Set<String> = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            let isDefault = line.hasPrefix("* ")
            var name = String(line.dropFirst(2))
                .trimmingCharacters(in: .whitespaces)
            if let marker = name.range(of: " (default)") {
                name = String(name[name.startIndex..<marker.lowerBound])
            }
            name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            options.append(GrokModelOption(id: name, isDefault: isDefault))
        }
        return options
    }

    /// Runs `grok models` and parses the result. Returns an empty list when
    /// the executable cannot be run, so the editor degrades to "Grok default"
    /// instead of failing.
    static func available(
        grokExecutablePath: String,
        timeout: TimeInterval = 15
    ) -> [GrokModelOption] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: grokExecutablePath)
        process.arguments = ["models"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let handle = output.fileHandleForReading
        let data = handle.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            return []
        }
        return parse(String(decoding: data, as: UTF8.self))
    }
}
