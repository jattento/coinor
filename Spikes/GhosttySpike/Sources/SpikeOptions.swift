import Foundation

struct SpikeOptions {
    let workingDirectory: String
    let command: String
    let eventLogPath: String?
    let automation: Bool
    let exitAfter: TimeInterval?

    static func parse(arguments: [String], bundle: Bundle) throws -> SpikeOptions {
        var workingDirectory = NSHomeDirectory()
        var commandPath = bundle.path(forResource: "ghostty-spike-command", ofType: "sh")
        var eventLogPath: String?
        var automation = false
        var exitAfter: TimeInterval?

        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--cwd":
                index += 1
                guard index < arguments.count else { throw SpikeError.invalidArgument("--cwd requires a value") }
                workingDirectory = arguments[index]
            case "--command":
                index += 1
                guard index < arguments.count else { throw SpikeError.invalidArgument("--command requires a value") }
                commandPath = arguments[index]
            case "--event-log":
                index += 1
                guard index < arguments.count else { throw SpikeError.invalidArgument("--event-log requires a value") }
                eventLogPath = arguments[index]
            case "--automation":
                automation = true
            case "--exit-after":
                index += 1
                guard index < arguments.count, let seconds = TimeInterval(arguments[index]) else {
                    throw SpikeError.invalidArgument("--exit-after requires seconds")
                }
                exitAfter = seconds
            case "--config-probe", "--resources":
                break
            default:
                break
            }
            index += 1
        }

        let normalizedDirectory = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard normalizedDirectory.hasPrefix("/"),
              FileManager.default.fileExists(atPath: normalizedDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SpikeError.invalidWorkingDirectory(normalizedDirectory)
        }

        guard let commandPath else { throw SpikeError.missingBundledCommand }
        let normalizedCommand = URL(fileURLWithPath: commandPath).standardizedFileURL.path
        guard normalizedCommand.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: normalizedCommand) else {
            throw SpikeError.invalidCommand(normalizedCommand)
        }

        return SpikeOptions(
            workingDirectory: normalizedDirectory,
            command: normalizedCommand,
            eventLogPath: eventLogPath,
            automation: automation,
            exitAfter: exitAfter
        )
    }

    var shellCommand: String {
        "/bin/zsh -f -- \(Self.shellQuote(command))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
enum SpikeError: LocalizedError {
    case invalidArgument(String)
    case invalidWorkingDirectory(String)
    case invalidCommand(String)
    case missingBundledCommand
    case missingResources(String)
    case ghosttyInitialization(Int32)
    case configurationCreation
    case applicationCreation
    case surfaceCreation

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message):
            message
        case .invalidWorkingDirectory(let path):
            "The working directory is not an existing absolute directory: \(path)"
        case .invalidCommand(let path):
            "The command is not an executable absolute path: \(path)"
        case .missingBundledCommand:
            "The bundled terminal command is missing."
        case .missingResources(let path):
            "Ghostty resources are missing at \(path)."
        case .ghosttyInitialization(let code):
            "ghostty_init failed with status \(code)."
        case .configurationCreation:
            "ghostty_config_new failed."
        case .applicationCreation:
            "ghostty_app_new failed."
        case .surfaceCreation:
            "ghostty_surface_new failed."
        }
    }
}
