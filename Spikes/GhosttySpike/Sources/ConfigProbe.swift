import Foundation

func runConfigProbe(resourcesDirectory: String) -> Int32 {
    let logger = SpikeLogger(path: nil)
    do {
        try GhosttyRuntime.initializeGhostty(resourcesDirectory: resourcesDirectory)
        let configuration = try GhosttyConfiguration(logger: logger)

        let fontSize = configuration.floatValue(for: "font-size") ?? -1
        let background = configuration.colorValue(for: "background")
        let payload: [String: Any] = [
            "fontSize": fontSize,
            "background": background.map {
                String(format: "%02x%02x%02x", $0.r, $0.g, $0.b)
            } ?? "missing",
            "diagnostics": configuration.diagnostics,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return configuration.diagnostics.isEmpty ? 0 : 3
    } catch {
        FileHandle.standardError.write(Data("config probe failed: \(error.localizedDescription)\n".utf8))
        return 1
    }
}
