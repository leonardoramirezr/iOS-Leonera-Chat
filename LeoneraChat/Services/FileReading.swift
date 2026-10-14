import Foundation
import UniformTypeIdentifiers

/// A file or an image picked for a mini app, ready to be sent.
struct PickedFile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var mimeType: String
    /// An image, scaled down as the chat sends photos, or a document sent as a data URL. None for a text file.
    var stored: StoredFile?
    /// A text file goes as its text: the API takes documents such as PDFs as files, not plain text.
    var text: String?

    var isImage: Bool { mimeType.hasPrefix("image/") }
}

enum FileReadingError: Error {
    case tooLarge
    case unreadable
}

enum FileReading {
    /// What the API takes in a file, and more than a phone should be holding in a request.
    static let maxFileSize = 25 * 1024 * 1024

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "html", "htm",
        "css", "js", "ts", "py", "sql", "log", "srt", "vtt",
    ]

    /// Reads a file picked in the Files app.
    static func read(_ url: URL) throws -> PickedFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        if type?.conforms(to: .image) == true {
            guard let data = try? Data(contentsOf: url) else { throw FileReadingError.unreadable }
            return try image(data, name: name)
        }
        if size > maxFileSize { throw FileReadingError.tooLarge }
        guard let data = try? Data(contentsOf: url) else { throw FileReadingError.unreadable }
        if data.count > maxFileSize { throw FileReadingError.tooLarge }

        if textExtensions.contains(url.pathExtension.lowercased()) || type?.conforms(to: .text) == true {
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return PickedFile(name: name, mimeType: type?.preferredMIMEType ?? "text/plain", text: text)
        }

        let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
        let stored = try BlobStore.save(data, mimeType: mimeType)
        return PickedFile(name: name, mimeType: mimeType, stored: stored)
    }

    /// Reads a photo: it is scaled down and stored like the ones sent in the chat.
    static func image(_ data: Data, name: String) throws -> PickedFile {
        guard let prepared = try? ImageProcessing.prepare(data) else { throw FileReadingError.unreadable }
        let stored = try BlobStore.save(prepared.data, mimeType: prepared.mimeType)
        return PickedFile(name: name, mimeType: prepared.mimeType, stored: stored)
    }
}
