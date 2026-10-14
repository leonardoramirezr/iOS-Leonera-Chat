import Foundation

// Minimal client for the parts of the OpenAI API the app uses, called directly from the device.

enum InputContent: Encodable {
    /// A data URL.
    case image(String)
    case text(String)
    /// A document, a PDF for instance, as a data URL.
    case file(name: String, data: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, filename
        case imageURL = "image_url"
        case fileData = "file_data"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .image(let url):
            try container.encode("input_image", forKey: .type)
            try container.encode(url, forKey: .imageURL)
        case .text(let text):
            try container.encode("input_text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .file(let name, let data):
            try container.encode("input_file", forKey: .type)
            try container.encode(name, forKey: .filename)
            try container.encode(data, forKey: .fileData)
        }
    }
}

enum InputItem: Encodable {
    case system(String)
    case assistant(String)
    case user([InputContent])

    private enum CodingKeys: String, CodingKey { case role, content }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .system(let text):
            try container.encode("system", forKey: .role)
            try container.encode(text, forKey: .content)
        case .assistant(let text):
            try container.encode("assistant", forKey: .role)
            try container.encode(text, forKey: .content)
        case .user(let content):
            try container.encode("user", forKey: .role)
            try container.encode(content, forKey: .content)
        }
    }
}

struct ResponseRequest: Encodable {
    struct Tool: Encodable {
        var type = "image_generation"
        var model: String
    }

    var stream = false
    /// Runs the response asynchronously so it can be polled, and picked up again after the app was closed.
    var background = true
    var model: String
    var tools: [Tool]
    var input: [InputItem]
}

struct OpenAIResponse: Decodable {
    struct Part: Decodable {
        let type: String
        let text: String?
        let refusal: String?

        enum CodingKeys: String, CodingKey { case type, text, refusal }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = (try? container.decode(String.self, forKey: .type)) ?? ""
            text = try? container.decodeIfPresent(String.self, forKey: .text)
            refusal = try? container.decodeIfPresent(String.self, forKey: .refusal)
        }
    }

    struct OutputItem: Decodable {
        let type: String
        /// `message` items.
        let content: [Part]?
        /// `image_generation_call` items: the base64-encoded image.
        let result: String?

        enum CodingKeys: String, CodingKey { case type, content, result }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = (try? container.decode(String.self, forKey: .type)) ?? ""
            content = try? container.decodeIfPresent([Part].self, forKey: .content)
            result = try? container.decodeIfPresent(String.self, forKey: .result)
        }
    }

    struct Failure: Decodable {
        let message: String?
    }

    struct IncompleteDetails: Decodable {
        let reason: String?
    }

    let id: String
    /// queued, in_progress, completed, failed, cancelled or incomplete.
    let status: String
    let output: [OutputItem]?
    let error: Failure?
    let incompleteDetails: IncompleteDetails?

    enum CodingKeys: String, CodingKey {
        case id, status, output, error
        case incompleteDetails = "incomplete_details"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(String.self, forKey: .status)
        output = try? container.decodeIfPresent([OutputItem].self, forKey: .output)
        error = try? container.decodeIfPresent(Failure.self, forKey: .error)
        incompleteDetails = try? container.decodeIfPresent(IncompleteDetails.self, forKey: .incompleteDetails)
    }

    var isRunning: Bool { status == "queued" || status == "in_progress" }

    var isGeneratingImage: Bool {
        output?.contains { $0.type == "image_generation_call" && $0.result == nil } ?? false
    }

    /// The reply text and the generated images.
    func read() -> (text: String, images: [Data]) {
        var texts: [String] = []
        var images: [Data] = []
        for item in output ?? [] {
            if item.type == "message" {
                for part in item.content ?? [] {
                    let text = part.type == "refusal" ? part.refusal : part.text
                    if let text, !text.isEmpty { texts.append(text) }
                }
            } else if item.type == "image_generation_call", let result = item.result,
                      let data = Data(base64Encoded: result, options: .ignoreUnknownCharacters) {
                images.append(data)
            }
        }
        return (texts.joined(separator: "\n\n"), images)
    }
}

struct OpenAIClient {
    let apiKey: String

    private static let baseURL = URL(string: "https://api.openai.com/v1")!

    /// Model IDs available to the API key, newest first.
    func modelIDs() async throws -> [String] {
        struct List: Decodable {
            struct Model: Decodable {
                let id: String
                let created: Int?
            }

            let data: [Model]
        }

        let list: List = try await call("models", timeout: 20)
        return list.data.sorted { ($0.created ?? 0) > ($1.created ?? 0) }.map(\.id)
    }

    func createResponse(_ request: ResponseRequest) async throws -> OpenAIResponse {
        try await call("responses", method: "POST", body: try JSONEncoder().encode(request))
    }

    func retrieveResponse(_ id: String) async throws -> OpenAIResponse {
        try await call("responses/\(Self.escape(id))", timeout: 20)
    }

    func cancelResponse(_ id: String) async throws {
        let _: OpenAIResponse = try await call("responses/\(Self.escape(id))/cancel", method: "POST")
    }

    private func call<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        timeout: TimeInterval = 60
    ) async throws -> T {
        try Task.checkCancellation()

        var request = URLRequest(url: URL(string: "\(Self.baseURL.absoluteString)/\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let data = try await HTTP.send(request, to: .openAI)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError(service: .openAI, message: "Invalid response", status: 0, code: nil)
        }
    }

    private static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }
}
