import Foundation

// Minimal client for the one part of the Groq API the app uses: Whisper turns what was dictated into text.

struct GroqClient {
    /// Speech to text.
    static let transcriptionModel = "whisper-large-v3"

    let apiKey: String

    private static let baseURL = "https://api.groq.com/openai/v1"

    /// Only asked for to tell whether a key is good.
    func checkKey() async throws {
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/models")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        _ = try await HTTP.send(request, to: .groq)
    }

    /// What was said, as text. Empty when all Whisper heard was silence or noise.
    func transcribe(audio: URL, language: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"dictation.m4a\"\r\n")
        body.append("Content-Type: audio/m4a\r\n\r\n")
        body.append(try Data(contentsOf: audio))
        body.append("\r\n")
        field("model", Self.transcriptionModel)
        // Told rather than detected: a short message is too little for Whisper to be sure of the
        // language, and on a wrong guess it writes down what was said in the other one.
        field("language", language)
        // Segment by segment, each with how sure Whisper is that it heard speech at all.
        field("response_format", "verbose_json")
        field("temperature", "0")
        body.append("--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        struct Transcription: Decodable {
            struct Segment: Decodable {
                let text: String
                let avg_logprob: Double
                let no_speech_prob: Double
            }

            let text: String?
            let segments: [Segment]?
        }

        let data = try await HTTP.send(request, to: .groq)
        guard let result = try? JSONDecoder().decode(Transcription.self, from: data) else {
            throw APIError(service: .groq, message: "Invalid response", status: 0, code: nil)
        }
        guard let segments = result.segments else {
            return (result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Out of silence Whisper makes words up («Gracias.», «Thanks for watching!»). This is its own
        // rule for telling: a segment it doubts is speech, and whose words it is unsure of, is dropped.
        return segments
            .filter { !($0.no_speech_prob > 0.6 && $0.avg_logprob < -1) }
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
