import Foundation
import Speech

protocol TelegramTranscribing: Sendable {
    func transcribe(data: Data, mimeType: String) async -> String?
}

protocol TelegramSpeechEngine: Sendable {
    func requestAuthorization() async -> Bool
    func recognizeFile(
        at url: URL,
        retainTask: @escaping @Sendable (AnyObject) -> Void
    ) async -> String?
}

/// On-Mac Speech engine. Authorization is requested before each recognition,
/// and the `SFSpeechRecognitionTask` is retained until it finishes — Speech
/// cancels the task if nothing holds it.
final class SystemSpeechEngine: TelegramSpeechEngine, @unchecked Sendable {
    static let shared = SystemSpeechEngine()

    private let lock = NSLock()
    private var recognitionTask: SFSpeechRecognitionTask?

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func recognizeFile(
        at url: URL,
        retainTask: @escaping @Sendable (AnyObject) -> Void
    ) async -> String? {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            return nil
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: text.isEmpty ? nil : text)
                } else if result == nil || error != nil {
                    finished = true
                    continuation.resume(returning: nil)
                }
            }
            retainTask(task)
            self.lock.withLock { recognitionTask = task }
        }
    }
}

/// Downloads are already done by the bridge. This type writes a temp file,
/// asks Speech for authorization, retains the recognition task, and returns
/// the transcript used in the ACP turn.
final class SpeechTelegramTranscriber: TelegramTranscribing, @unchecked Sendable {
    private let engine: any TelegramSpeechEngine
    private let lock = NSLock()
    private var retainedTask: AnyObject?

    init(engine: any TelegramSpeechEngine = SystemSpeechEngine.shared) {
        self.engine = engine
    }

    func transcribe(data: Data, mimeType: String) async -> String? {
        let ext = mimeType.contains("mpeg") || mimeType.contains("mp3")
            ? "mp3"
            : mimeType.contains("m4a") || mimeType.contains("mp4")
                ? "m4a"
                : mimeType.contains("wav") ? "wav" : "ogg"
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("coinor-voice-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            guard await engine.requestAuthorization() else {
                return nil
            }
            if let text = await recognize(source) {
                return text
            }
            let wav = source.deletingPathExtension().appendingPathExtension("wav")
            guard convertToWAV(source, wav) else {
                return nil
            }
            defer { try? FileManager.default.removeItem(at: wav) }
            return await recognize(wav)
        } catch {
            return nil
        }
    }

    private func recognize(_ url: URL) async -> String? {
        await engine.recognizeFile(at: url) { [weak self] task in
            self?.lock.withLock { self?.retainedTask = task }
        }
    }

    private func convertToWAV(_ source: URL, _ destination: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "WAVE", "-d", "LEI16", source.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
                && FileManager.default.isReadableFile(atPath: destination.path)
        } catch {
            return false
        }
    }
}
