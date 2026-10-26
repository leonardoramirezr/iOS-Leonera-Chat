import Foundation

/// Where a reply lives: the chat's conversation, or a mini app's last run.
@MainActor
protocol ReplyHost: AnyObject {
    func reply(_ id: UUID) -> Message?
    /// Changes the reply, if it is still there.
    func update(reply id: UUID, _ change: (inout Message) -> Void)
    func save()
    /// Whether the raw JSON of the response is kept with the reply, to be shown in the app.
    var keepsRawResponse: Bool { get }
}

/// What the chat and the mini apps share: a background response followed until it ends, and its output
/// written into the message that shows it.
@MainActor
enum ReplyRunner {
    private static let pollInterval: Duration = .seconds(2)
    /// Consecutive connection failures tolerated while polling, e.g. while the phone is locked.
    private static let maxPollFailures = 8

    /// Creates the response from its JSON body, and follows it until it ends.
    static func send(_ body: Data, apiKey: String, host: ReplyHost, reply id: UUID) async throws {
        let client = OpenAIClient(apiKey: apiKey)
        let created = try await client.createResponse(body)
        host.update(reply: id) { $0.responseId = created.response.id }
        host.save()
        try await follow(client, responseID: created.response.id, first: created, host: host, reply: id)
    }

    /// Picks up a response created earlier, e.g. before the app was closed.
    static func resume(apiKey: String, host: ReplyHost, reply id: UUID) async throws {
        guard let responseID = host.reply(id)?.responseId else { throw CancellationError() }
        try await follow(OpenAIClient(apiKey: apiKey), responseID: responseID, first: nil, host: host, reply: id)
    }

    /// Marks the reply as failed with what went wrong, if it was still waiting.
    static func fail(_ host: ReplyHost, reply id: UUID, error: Error) {
        var changed = false
        host.update(reply: id) { message in
            guard message.status == .pending else { return }
            changed = true
            message.status = .failed
            message.phase = nil
            message.error = describe(error, responseID: message.responseId)
        }
        if changed { host.save() }
    }

    /// Cancels the response on OpenAI's side too. Nobody waits for the answer.
    static func cancel(responseID: String?, apiKey: String) {
        guard let responseID else { return }
        Task.detached {
            try? await OpenAIClient(apiKey: apiKey).cancelResponse(responseID)
        }
    }

    private static func follow(
        _ client: OpenAIClient,
        responseID: String,
        first: FetchedResponse?,
        host: ReplyHost,
        reply id: UUID
    ) async throws {
        var fetched = first
        var failures = 0

        while true {
            if let response = fetched?.response {
                guard response.isRunning else { break }
                let phase: Message.Phase = response.isGeneratingImage ? .image : .thinking
                host.update(reply: id) { message in
                    if message.status == .pending, message.phase != phase { message.phase = phase }
                }
            }
            if fetched != nil || failures > 0 { try await Task.sleep(for: pollInterval) }

            do {
                fetched = try await client.retrieveResponse(responseID)
                failures = 0
            } catch let error as APIError where error.isTransient {
                failures += 1
                if failures >= maxPollFailures { throw error }
            }
        }

        guard let last = fetched else { return }
        let output = await store(last, keepsRaw: host.keepsRawResponse)

        var finished = false
        host.update(reply: id) {
            finished = finish(&$0, response: last.response, text: output.text, images: output.images, raw: output.raw)
        }
        if finished {
            host.save()
        } else {
            // Stopped while the images were on their way.
            BlobStore.delete(output.images.flatMap { [$0.full, $0.input] } + [output.raw].compactMap { $0 })
        }
    }

    /// Writes the generated images to disk, each with the lighter copy sent back in later turns, and the
    /// response's JSON when it is kept.
    private nonisolated static func store(
        _ fetched: FetchedResponse,
        keepsRaw: Bool
    ) async -> (text: String, images: [GeneratedImage], raw: StoredFile?) {
        let (text, images) = fetched.response.read()
        let generated = images.compactMap { data -> GeneratedImage? in
            guard let full = try? BlobStore.save(data, mimeType: ImageProcessing.mimeType(of: data)) else { return nil }
            guard let prepared = try? ImageProcessing.prepare(data),
                  let input = try? BlobStore.save(prepared.data, mimeType: prepared.mimeType)
            else { return GeneratedImage(full: full, input: full) }
            return GeneratedImage(full: full, input: input)
        }
        var raw: StoredFile?
        if keepsRaw { raw = try? BlobStore.save(fetched.raw, mimeType: "application/json") }
        return (text, generated, raw)
    }

    /// Writes a finished response into its message. False when the message stopped waiting for it.
    private static func finish(
        _ message: inout Message,
        response: OpenAIResponse,
        text: String,
        images: [GeneratedImage],
        raw: StoredFile?
    ) -> Bool {
        guard message.status == .pending else { return false }

        message.text = text
        message.images = images
        message.rawResponse = raw
        message.phase = nil

        switch response.status {
        case "failed":
            message.status = .failed
            message.error = MessageError(message: response.error?.message ?? String(localized: "Something went wrong."))
        case "cancelled":
            message.status = .cancelled
        default:
            message.status = .done
            if response.status == "incomplete" {
                if let reason = response.incompleteDetails?.reason {
                    message.notice = String(localized: "The response is incomplete (\(reason)).")
                } else {
                    message.notice = String(localized: "The response is incomplete.")
                }
            } else if text.isEmpty && images.isEmpty {
                message.notice = String(localized: "The response was empty.")
            }
        }
        return true
    }

    private static func describe(_ error: Error, responseID: String?) -> MessageError {
        if let error = error as? APIError {
            return MessageError(
                message: error.status == 0
                    ? String(localized: "Couldn't reach OpenAI. Check your connection and try again.")
                    : error.message,
                auth: error.status == 401,
                resumable: responseID != nil && error.isTransient
            )
        }
        if error is CancellationError {
            return MessageError(message: String(localized: "The request was interrupted."), resumable: responseID != nil)
        }
        return MessageError(message: String(localized: "Something went wrong."))
    }
}
