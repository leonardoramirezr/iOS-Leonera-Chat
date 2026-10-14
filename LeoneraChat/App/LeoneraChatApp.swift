import SwiftUI

@main
@MainActor
struct LeoneraChatApp: App {
    @State private var settings: SettingsStore
    @State private var chat: ChatStore
    @State private var miniApps: MiniAppStore
    @State private var runs: RunStore

    init() {
        let settings = SettingsStore()
        _settings = State(initialValue: settings)
        _chat = State(initialValue: ChatStore(settings: settings))
        _miniApps = State(initialValue: MiniAppStore())
        _runs = State(initialValue: RunStore(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(chat)
                .environment(miniApps)
                .environment(runs)
        }
    }
}

enum AppTab: String {
    case chat, miniApps, settings
}

struct RootView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chat
    @Environment(MiniAppStore.self) private var miniApps
    @Environment(RunStore.self) private var runs
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("tab") private var tab: AppTab = .chat
    @State private var cleaned = false

    var body: some View {
        if settings.apiKey.isEmpty {
            OnboardingView()
        } else {
            TabView(selection: $tab) {
                NavigationStack {
                    ChatView(openSettings: { tab = .settings })
                }
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppTab.chat)

                MiniAppsTab()
                    .tabItem { Label("Mini apps", systemImage: "sparkles") }
                    .tag(AppTab.miniApps)

                NavigationStack {
                    SettingsView()
                }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
            }
            .task { start() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                chat.resumeIfNeeded()
                runs.resumeIfNeeded()
            }
        }
    }

    /// Restores the conversation and the mini apps' runs, resuming the responses still running, and
    /// deletes the images nothing refers to any more.
    private func start() {
        chat.load()
        runs.load(miniApps.apps)
        guard !cleaned else { return }
        cleaned = true
        let kept = Set((chat.storedFiles + runs.storedFiles).map(\.name))
        BlobStore.removeAll(except: kept)
    }
}
