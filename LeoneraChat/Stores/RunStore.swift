import Foundation
import Observation

/// Each mini app keeps its last run on this device, as the chat keeps its conversation. A run goes on
/// in the background while the user is elsewhere, and is picked up again after the app is reopened.
@MainActor
@Observable
final class RunStore: ReplyHost {
    private(set) var runs: [UUID: Run] = [:]
    /// Files still being read, by the input they were picked for. Never stored.
    private(set) var reading: [UUID: Int] = [:]

    private let settings: SettingsStore
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var saves: [UUID: Task<Void, Never>] = [:]

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func run(_ app: UUID) -> Run {
        runs[app] ?? Run()
    }

    var storedFiles: [StoredFile] { runs.values.flatMap(\.storedFiles) }

    /// Reads the last run of every mini app, and resumes the responses that were still running.
    func load(_ apps: [MiniApp]) {
        for app in apps where runs[app.id] == nil {
            guard let saved = Storage.load(Run.self, from: Self.file(app.id)) else { continue }
            runs[app.id] = saved
            guard let result = saved.result, result.isPending else { continue }
            if result.responseId != nil {
                follow(app.id, reply: result.id)
            } else {
                ReplyRunner.fail(self, reply: result.id, error: CancellationError())
            }
        }
    }

    func isRunning(_ app: UUID) -> Bool {
        runs[app]?.result?.isPending == true
    }

    func isReading(_ app: MiniApp) -> Bool {
        app.inputs.contains { (reading[$0.id] ?? 0) > 0 }
    }

    // MARK: Answers and files

    func answer(_ app: UUID, _ question: String) -> String {
        runs[app]?.answers[question] ?? ""
    }

    /// Saves what was answered a moment after the last key, rather than on every one.
    func setAnswer(_ app: UUID, _ question: String, _ answer: String) {
        runs[app, default: Run()].answers[question] = answer
        saveSoon(app)
    }

    func beginReading(_ input: UUID, count: Int) {
        reading[input, default: 0] += count
    }

    func endReading(_ input: UUID) {
        reading[input] = max(0, (reading[input] ?? 0) - 1)
    }

    func add(_ file: PickedFile, to app: UUID, input: UUID) {
        runs[app, default: Run()].files[input, default: []].append(file)
        save(app)
    }

    func remove(_ file: PickedFile, from app: UUID, input: UUID) {
        runs[app]?.files[input]?.removeAll { $0.id == file.id }
        if let stored = file.stored { BlobStore.delete([stored]) }
        save(app)
    }

    // MARK: Running

    func send(_ app: MiniApp) {
        guard !isRunning(app.id), !isReading(app) else { return }

        if let old = runs[app.id]?.result { BlobStore.delete(old.files) }
        let reply = Message.pendingReply()
        runs[app.id, default: Run()].result = reply
        save(app.id)

        let run = self.run(app.id)
        let apiKey = settings.apiKey
        let model = settings.textModel
        let imageModel = settings.imageModel
        start(app.id) {
            let request = await MiniAppRequest.make(app: app, run: run, model: model, imageModel: imageModel)
            let body = try OpenAIClient.body(for: request)
            await self.keepRequest(body, reply: reply.id, app: app.id)
            try await ReplyRunner.send(body, apiKey: apiKey, host: self, reply: reply.id)
        } failing: { error in
            ReplyRunner.fail(self, reply: reply.id, error: error)
        }
    }

    func retry(_ app: MiniApp) {
        guard let result = runs[app.id]?.result, result.status == .failed else { return }

        if result.error?.resumable == true {
            update(reply: result.id) { message in
                message.status = .pending
                message.phase = .thinking
                message.error = nil
            }
            save(app.id)
            follow(app.id, reply: result.id)
        } else {
            send(app)
        }
    }

    func stop(_ app: UUID) {
        guard let result = runs[app]?.result, result.isPending else { return }
        update(reply: result.id) { message in
            message.status = .cancelled
            message.phase = nil
        }
        tasks[app]?.cancel()
        ReplyRunner.cancel(responseID: result.responseId, apiKey: settings.apiKey)
        save(app)
    }

    /// Empties the answers, the files and the result, to start again.
    func clear(_ app: UUID) {
        stop(app)
        let files = run(app).storedFiles
        runs[app] = Run()
        save(app)
        BlobStore.delete(files)
    }

    /// Drops what a deleted mini app left on the device.
    func forget(_ app: UUID) {
        stop(app)
        saves[app]?.cancel()
        BlobStore.delete(run(app).storedFiles)
        runs[app] = nil
        Storage.delete(Self.file(app))
    }

    /// When the app comes back to the foreground: a response whose polling died is picked up again.
    func resumeIfNeeded() {
        for (app, run) in runs where tasks[app] == nil {
            guard let result = run.result, result.isPending, result.responseId != nil else { continue }
            follow(app, reply: result.id)
        }
    }

    /// Keeps the request exactly as it is sent, so the run can show it.
    private func keepRequest(_ body: Data, reply id: UUID, app: UUID) async {
        let file = await Task.detached { try? BlobStore.save(body, mimeType: "application/json") }.value
        guard let file else { return }
        update(reply: id) { $0.rawRequest = file }
        save(app)
    }

    private func follow(_ app: UUID, reply id: UUID) {
        let apiKey = settings.apiKey
        start(app) {
            try await ReplyRunner.resume(apiKey: apiKey, host: self, reply: id)
        } failing: { error in
            ReplyRunner.fail(self, reply: id, error: error)
        }
    }

    private func start(_ app: UUID, _ work: @escaping () async throws -> Void, failing: @escaping (Error) -> Void) {
        tasks[app]?.cancel()
        let current = Task {
            do {
                try await work()
            } catch {
                failing(error)
            }
        }
        tasks[app] = current
        Task {
            await current.value
            if tasks[app] == current { tasks[app] = nil }
        }
    }

    private func saveSoon(_ app: UUID) {
        saves[app]?.cancel()
        saves[app] = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save(app)
        }
    }

    private func save(_ app: UUID) {
        saves[app]?.cancel()
        saves[app] = nil
        guard let run = runs[app] else { return }
        Storage.save(run, to: Self.file(app))
    }

    private static func file(_ app: UUID) -> String {
        "run-\(app.uuidString).json"
    }

    // MARK: ReplyHost

    func reply(_ id: UUID) -> Message? {
        runs.values.lazy.compactMap(\.result).first { $0.id == id }
    }

    func update(reply id: UUID, _ change: (inout Message) -> Void) {
        guard let app = runs.first(where: { $0.value.result?.id == id })?.key else { return }
        if var result = runs[app]?.result {
            change(&result)
            runs[app]?.result = result
        }
    }

    func save() {
        for app in runs.keys { save(app) }
    }

    /// Each run keeps the JSON it was sent and answered with, to show it.
    var keepsRawResponse: Bool { true }
}
