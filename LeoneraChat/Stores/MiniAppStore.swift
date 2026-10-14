import Foundation
import Observation

/// The mini apps: prompts that ask before they are sent, each run for one result.
@MainActor
@Observable
final class MiniAppStore {
    private(set) var apps: [MiniApp]

    private static let file = "mini-apps.json"

    init() {
        apps = Storage.load([MiniApp].self, from: Self.file) ?? []
    }

    /// Newest first, which is how the list shows them.
    var sorted: [MiniApp] { apps.sorted { $0.createdAt > $1.createdAt } }

    func app(_ id: UUID?) -> MiniApp? {
        guard let id else { return nil }
        return apps.first { $0.id == id }
    }

    @discardableResult
    func add(name: String, prompt: String, inputs: [MiniAppInput]) -> MiniApp {
        let app = MiniApp(name: name, prompt: prompt, inputs: inputs)
        apps.append(app)
        save()
        return app
    }

    func update(_ id: UUID, name: String, prompt: String, inputs: [MiniAppInput]) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[index].name = name
        apps[index].prompt = prompt
        apps[index].inputs = inputs
        save()
    }

    func remove(_ id: UUID) {
        apps.removeAll { $0.id == id }
        save()
    }

    private func save() {
        Storage.save(apps, to: Self.file)
    }
}
