import SwiftUI

/// A message of the chat, or the result of a mini app.
struct MessageView: View {
    let message: Message
    /// Only the last message offers to retry.
    var isLast = true
    var onView: (StoredFile) -> Void
    var onRetry: () -> Void
    var onUpdateKey: () -> Void

    var body: some View {
        if message.role == .user {
            UserMessageView(message: message, onView: onView)
        } else {
            assistant
        }
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 12) {
            if message.status == .pending {
                if message.phase == .image {
                    ImagePlaceholder(startedAt: message.startedAt)
                } else {
                    WorkingLabel(title: "Thinking", startedAt: message.startedAt)
                }
            }

            ForEach(message.images, id: \.full) { image in
                GeneratedImageView(file: image.full, onView: onView)
            }

            if !message.text.isEmpty {
                MarkdownView(text: message.text)
            }

            if let notice = message.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            switch message.status {
            case .cancelled:
                Label("Stopped", systemImage: "stop.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failed:
                failure
            case .done where !message.text.isEmpty:
                TextActions(text: message.text)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var failure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                message.error?.message ?? String(localized: "Something went wrong."),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.red)

            if isLast {
                HStack {
                    if message.error?.auth == true {
                        Button("Update API key", action: onUpdateKey)
                            .buttonStyle(.bordered)
                    }
                    Button(action: onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct UserMessageView: View {
    let message: Message
    var onView: (StoredFile) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.photos.isEmpty {
                photos
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = message.text
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }

    private var photos: some View {
        let single = message.photos.count == 1
        let side: CGFloat = single ? 220 : 96
        let columns = Array(repeating: GridItem(.fixed(side), spacing: 6), count: min(message.photos.count, 3))
        return LazyVGrid(columns: columns, alignment: .trailing, spacing: 6) {
            ForEach(message.photos) { photo in
                Button {
                    onView(photo)
                } label: {
                    StoredImageView(file: photo, maxPixelSize: single ? 660 : 300, contentMode: .fill)
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Attached photo"))
            }
        }
        .fixedSize()
    }
}

private struct GeneratedImageView: View {
    let file: StoredFile
    var onView: (StoredFile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onView(file)
            } label: {
                StoredImageView(file: file, maxPixelSize: 1400)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .frame(maxWidth: 440, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Generated image"))
            .contextMenu {
                SaveImageButton(file: file)
                ShareLink(item: BlobStore.url(for: file))
            }

            HStack(spacing: 8) {
                SaveImageButton(file: file)
                ShareLink(item: BlobStore.url(for: file)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

/// Copying and sharing what the assistant wrote.
struct TextActions: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 16) {
            Button {
                UIPasteboard.general.string = text
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(
                    copied ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy"),
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
            }
            ShareLink(item: text) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .labelStyle(.iconOnly)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .buttonStyle(.borderless)
    }
}

/// «Thinking 12s», pulsing while the response is on its way.
struct WorkingLabel: View {
    let title: LocalizedStringKey
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                Text(title)
                    .phaseAnimator([0.45, 1]) { content, opacity in
                        content.opacity(opacity)
                    } animation: { _ in
                        .easeInOut(duration: 0.9)
                    }
                Text(verbatim: "\(max(0, Int(context.date.timeIntervalSince(startedAt))))s")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct ImagePlaceholder: View {
    let startedAt: Date

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 320)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                        .symbolEffect(.pulse)
                    WorkingLabel(title: "Creating image", startedAt: startedAt)
                }
            }
    }
}
