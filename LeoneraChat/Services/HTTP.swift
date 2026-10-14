import Foundation

/// What went wrong talking to OpenAI or Groq.
struct APIError: LocalizedError {
    enum Service {
        case openAI, groq
    }

    let service: Service
    let message: String
    /// 0 when the service couldn't be reached.
    let status: Int
    let code: String?

    var errorDescription: String? { message }

    /// Whether repeating the same call may succeed.
    var isTransient: Bool {
        status == 0 || status >= 500 || (status == 429 && code != "insufficient_quota")
    }
}

/// The few HTTP calls the app makes, straight from the device to each API.
enum HTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    static func send(_ request: URLRequest, to service: APIError.Service) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw APIError(service: service, message: "Network error", status: 0, code: nil)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            let fallback = "\(status) \(HTTPURLResponse.localizedString(forStatusCode: status))"
            throw APIError(
                service: service,
                message: body?.error?.message ?? fallback,
                status: status,
                code: body?.error?.code
            )
        }
        return data
    }
}

private struct ErrorBody: Decodable {
    struct Detail: Decodable {
        let message: String?
        let code: String?

        enum CodingKeys: String, CodingKey { case message, code }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
            code = try? container.decodeIfPresent(String.self, forKey: .code)
        }
    }

    let error: Detail?
}

extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
