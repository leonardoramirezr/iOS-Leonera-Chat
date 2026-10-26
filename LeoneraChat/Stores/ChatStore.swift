import Foundation
import Observation

/// The conversation. It is full of images, so it stays on this device, with the images as files.
@MainActor
@Observable
final class ChatStore: ReplyHost {
    private(set) var messages: [Message] = []
    private(set) var loaded = false

    private let settings: SettingsStore
    @ObservationIgnored private var task: Task<Void, Never>?

    private static let file = "conversation.json"

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// The last message, while its response is in progress.
    var pending: Message? {
        guard let last = messages.last, last.isPending else { return nil }
        return last
    }

    var storedFiles: [StoredFile] { messages.flatMap(\.files) }

    /// Restores the saved conversation and resumes a response that was still running.
    func load() {
        guard !loaded else { return }
        messages = Storage.load([Message].self, from: Self.file) ?? []
        loaded = true

        guard let pending else { return }
        if pending.responseId != nil {
            follow(pending.id)
        } else {
            ReplyRunner.fail(self, reply: pending.id, error: CancellationError())
        }
    }

    func send(text: String, photos: [StoredFile]) {
        guard loaded, pending == nil else { return }
        messages.append(.user(text, photos: photos))
        respond()
    }

    func retry() {
        guard let last = messages.last, last.role == .assistant, last.status == .failed else { return }

        if last.error?.resumable == true {
            update(reply: last.id) { message in
                message.status = .pending
                message.phase = .thinking
                message.error = nil
            }
            save()
            follow(last.id)
        } else {
            BlobStore.delete(last.files)
            messages.removeLast()
            respond()
        }
    }

    func stop() {
        guard let reply = pending else { return }
        update(reply: reply.id) { message in
            message.status = .cancelled
            message.phase = nil
        }
        task?.cancel()
        ReplyRunner.cancel(responseID: reply.responseId, apiKey: settings.apiKey)
        save()
    }

    /// Starts a new chat: this conversation, and its images, are deleted.
    func clear() {
        stop()
        let files = storedFiles
        messages = []
        save()
        BlobStore.delete(files)
    }

    /// When the app comes back to the foreground: a response whose polling died is picked up again.
    func resumeIfNeeded() {
        guard let pending, pending.responseId != nil, task == nil else { return }
        follow(pending.id)
    }

    private func respond() {
        let history = messages
        let reply = Message.pendingReply()
        messages.append(reply)
        save()

        let apiKey = settings.apiKey
        let model = settings.textModel
        let imageModel = settings.imageModel
        start {
            let request = await ChatRequest.make(history: history, model: model, imageModel: imageModel)
            try await ReplyRunner.send(try OpenAIClient.body(for: request), apiKey: apiKey, host: self, reply: reply.id)
        } failing: { error in
            ReplyRunner.fail(self, reply: reply.id, error: error)
        }
    }

    private func follow(_ id: UUID) {
        let apiKey = settings.apiKey
        start {
            try await ReplyRunner.resume(apiKey: apiKey, host: self, reply: id)
        } failing: { error in
            ReplyRunner.fail(self, reply: id, error: error)
        }
    }

    private func start(_ work: @escaping () async throws -> Void, failing: @escaping (Error) -> Void) {
        task?.cancel()
        let current = Task {
            do {
                try await work()
            } catch {
                failing(error)
            }
        }
        task = current
        Task {
            await current.value
            if task == current { task = nil }
        }
    }

    // MARK: ReplyHost

    func reply(_ id: UUID) -> Message? {
        messages.first { $0.id == id }
    }

    func update(reply id: UUID, _ change: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    func save() {
        Storage.save(messages, to: Self.file)
    }

    /// The chat sends the whole conversation on every turn: its raw JSON is not kept.
    var keepsRawResponse: Bool { false }
}
