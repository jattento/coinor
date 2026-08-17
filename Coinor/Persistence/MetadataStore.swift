import Foundation

/// Why a load or save against the metadata file failed, phrased for direct
/// display. Every case leaves the file on disk exactly as it was found.
enum MetadataStoreError: LocalizedError, Sendable {
    case unreadable(url: URL, reason: String)
    case corrupt(url: URL, reason: String)
    case unsupportedSchemaVersion(found: Int, supported: Int, url: URL)

    var errorDescription: String? {
        switch self {
        case let .unreadable(url, reason):
            return "Conan Code could not read its metadata file at \(url.path): \(reason). "
                + "The file was left untouched."
        case let .corrupt(url, reason):
            return "Conan Code's metadata file at \(url.path) is not valid JSON: \(reason). "
                + "The file was left untouched; back it up or delete it to reset Conan Code's "
                + "organization metadata."
        case let .unsupportedSchemaVersion(found, supported, url):
            return "Conan Code's metadata file at \(url.path) was written by a newer version of "
                + "Conan Code (schema \(found); this build supports up to \(supported)). "
                + "The file was left untouched; use a newer build of Conan Code to open it."
        }
    }
}

/// Owns Coinor's single versioned metadata document on disk.
///
/// The document is small, single-writer, and local, so a database is
/// unnecessary: every mutation reads the in-memory document, applies a pure
/// change, and replaces the file atomically through a temp-write-then-move.
/// Actor isolation serializes concurrent callers; a missing file bootstraps
/// to `MetadataDocument.empty` and a corrupt file fails loudly instead of
/// being silently discarded or overwritten.
actor MetadataStore {
    static let fileName = "metadata.json"

    private let fileURL: URL
    private let fileManager: FileManager
    private var document: MetadataDocument

    /// - Parameter directoryURL: The directory the metadata file lives
    ///   beneath. Tests inject a scratch directory; the live app injects its
    ///   Application Support directory.
    init(directoryURL: URL, fileManager: FileManager = .default) throws {
        self.fileURL = directoryURL.appendingPathComponent(Self.fileName)
        self.fileManager = fileManager
        self.document = try Self.loadDocument(at: fileURL, fileManager: fileManager)
    }

    var currentDocument: MetadataDocument {
        document
    }

    /// Applies a pure change to the document and persists the result before
    /// it becomes the store's in-memory state, so a failed write never
    /// leaves memory and disk disagreeing.
    @discardableResult
    func update(
        _ transform: @Sendable (inout MetadataDocument) -> Void
    ) throws -> MetadataDocument {
        var updated = document
        transform(&updated)
        try Self.write(updated, to: fileURL, fileManager: fileManager)
        document = updated
        return document
    }

    private static func loadDocument(at url: URL, fileManager: FileManager) throws -> MetadataDocument {
        guard fileManager.fileExists(atPath: url.path) else {
            return .empty
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MetadataStoreError.unreadable(url: url, reason: error.localizedDescription)
        }

        let decoded: MetadataDocument
        do {
            decoded = try JSONDecoder().decode(MetadataDocument.self, from: data)
        } catch {
            throw MetadataStoreError.corrupt(url: url, reason: String(describing: error))
        }

        guard decoded.schemaVersion >= 0 else {
            throw MetadataStoreError.unsupportedSchemaVersion(
                found: decoded.schemaVersion,
                supported: MetadataSchema.currentVersion,
                url: url
            )
        }

        guard decoded.schemaVersion <= MetadataSchema.currentVersion else {
            throw MetadataStoreError.unsupportedSchemaVersion(
                found: decoded.schemaVersion,
                supported: MetadataSchema.currentVersion,
                url: url
            )
        }

        return MetadataMigrator.migrate(decoded)
    }

    private static func write(_ document: MetadataDocument, to url: URL, fileManager: FileManager) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)

        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try data.write(to: tempURL)

        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }
}
