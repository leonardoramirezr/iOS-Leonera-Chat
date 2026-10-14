import SwiftUI

struct ChatView: View {
    var openSettings: () -> Void

    @Environment(ChatStore.self) private var chat
    @Environment(SettingsStore.self) private var settings

    @State private var viewing: StoredFile?
    @State private var confirmingNewChat = false

    private let bottom = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(chat.messages) { message in
                        MessageView(
                            message: message,
                            isLast: message.id == chat.messages.last?.id,
                            onView: { viewing = $0 },
                            onRetry: { chat.retry() },
                            onUpdateKey: { settings.apiKey = "" }
                        )
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottom)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if chat.loaded && chat.messages.isEmpty {
                    EmptyChatView()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerView(openSettings: openSettings) {
                    scrollToBottom(proxy)
                }
            }
            .onChange(of: chat.messages.count) { scrollToBottom(proxy) }
            .onChange(of: chat.messages.last?.status) { scrollToBottom(proxy) }
            .onChange(of: chat.messages.last?.phase) { scrollToBottom(proxy) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ModelMenu(openSettings: openSettings)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    confirmingNewChat = true
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .disabled(chat.messages.isEmpty)
            }
        }
        .confirmationDialog(
            "Start a new chat? This conversation will be deleted.",
            isPresented: $confirmingNewChat,
            titleVisibility: .visible
        ) {
            Button("New chat", role: .destructive) { chat.clear() }
        }
        .fullScreenCover(item: $viewing) { file in
            ImageViewer(file: file)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            // After the new content is laid out.
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(bottom, anchor: .bottom) }
        }
    }
}

private struct EmptyChatView: View {
    var body: some View {
        ContentUnavailableView {
            VStack(spacing: 16) {
                AppLogo(size: 64)
                Text("What do you want to create?")
            }
        } description: {
            Text("Ask anything, or add photos and describe the image you want.")
        }
        .allowsHitTesting(false)
    }
}

/// The title of the chat: which models it talks to, and a quick way to change them.
private struct ModelMenu: View {
    var openSettings: () -> Void

    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Menu {
            Menu {
                choices(settings.textModelOptions, selected: settings.textModel) { settings.textModel = $0 }
            } label: {
                Text("Text model")
                Text(verbatim: settings.textModel)
            }
            Menu {
                choices(settings.imageModelOptions, selected: settings.imageModel) { settings.imageModel = $0 }
            } label: {
                Text("Image model")
                Text(verbatim: settings.imageModel)
            }
            Divider()
            Button("Settings", systemImage: "gearshape", action: openSettings)
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text(verbatim: "Leonera Chat")
                        .font(.headline)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: "\(settings.textModel) · \(settings.imageModel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
        }
        .task { await settings.refreshModels() }
    }

    @ViewBuilder
    private func choices(_ options: [String], selected: String, select: @escaping (String) -> Void) -> some View {
        ForEach(options, id: \.self) { option in
            Button {
                select(option)
            } label: {
                if option == selected {
                    Label(option, systemImage: "checkmark")
                } else {
                    Text(verbatim: option)
                }
            }
        }
    }
}
