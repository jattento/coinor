import AppKit
import Foundation

func argumentValue(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1) else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}
if CommandLine.arguments.contains("--config-probe") {
    guard let resources = argumentValue("--resources") else {
        FileHandle.standardError.write(Data("--resources is required for --config-probe\n".utf8))
        exit(64)
    }
    exit(runConfigProbe(resourcesDirectory: resources))
}

do {
    let options = try SpikeOptions.parse(arguments: CommandLine.arguments, bundle: .main)
    let logger = SpikeLogger(path: options.eventLogPath)
    let delegate = SpikeApplicationDelegate(options: options, logger: logger)
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    application.delegate = delegate
    application.run()
} catch {
    FileHandle.standardError.write(Data("startup failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
