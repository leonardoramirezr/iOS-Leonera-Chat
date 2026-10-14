import Foundation

/// JSON documents in Application Support: the conversation, the mini apps and their last runs.
/// Images and files are kept apart, in `BlobStore`, so these stay small.
enum Storage {
    static let directory: URL = {
        let url = URL.applicationSupportDirectory.appending(path: "LeoneraChat", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: directory.appending(path: name), options: .atomic)
    }

    static func delete(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: name))
    }
}

/// An image or a file kept on the device, referenced by name from the JSON documents.
struct StoredFile: Codable, Hashable, Identifiable {
    /// The file's name in `BlobStore.directory`.
    let name: String
    let mimeType: String

    var id: String { name }
    var isImage: Bool { mimeType.hasPrefix("image/") }
}

enum BlobStore {
    static let directory: URL = {
        let url = Storage.directory.appending(path: "Blobs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func save(_ data: Data, mimeType: String) throws -> StoredFile {
        let file = StoredFile(name: "\(UUID().uuidString).\(fileExtension(for: mimeType))", mimeType: mimeType)
        try data.write(to: url(for: file), options: .atomic)
        return file
    }

    static func url(for file: StoredFile) -> URL {
        directory.appending(path: file.name)
    }

    static func data(for file: StoredFile) throws -> Data {
        try Data(contentsOf: url(for: file))
    }

    /// What the API takes for images and documents.
    static func dataURL(for file: StoredFile) throws -> String {
        "data:\(file.mimeType);base64,\(try data(for: file).base64EncodedString())"
    }

    static func delete(_ files: [StoredFile]) {
        for file in files {
            try? FileManager.default.removeItem(at: url(for: file))
        }
    }

    /// Deletes every file nothing refers to any more.
    static func removeAll(except kept: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names where !kept.contains(name) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/webp": "webp"
        case "image/gif": "gif"
        case "application/pdf": "pdf"
        default: "bin"
        }
    }
}
