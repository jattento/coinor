import Foundation
import Speech

protocol TelegramTranscribing: Sendable {
    func transcribe(data: Data, mimeType: String) async -> String?
}

struct SpeechTelegramTranscriber: TelegramTranscribing {
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
            if let text = await recognize(source) {
                return text
            }
            let wav = source.deletingPathExtension().appendingPathExtension("wav")
            guard convertToWAV(source, wav),
                  let text = await recognize(wav) else {
                return nil
            }
            try? FileManager.default.removeItem(at: wav)
            return text
        } catch {
            return nil
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

    private func recognize(_ url: URL) async -> String? {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            return nil
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, _ in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: text.isEmpty ? nil : text)
                } else if result == nil {
                    finished = true
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
