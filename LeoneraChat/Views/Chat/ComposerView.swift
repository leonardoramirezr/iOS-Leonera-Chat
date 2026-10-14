import PhotosUI
import SwiftUI

/// Where the message is written: text, photos, and dictation.
struct ComposerView: View {
    var openSettings: () -> Void
    var onSend: () -> Void

    @Environment(ChatStore.self) private var chat
    @Environment(SettingsStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase

    @State private var text = ""
    @State private var attachments: [Attachment] = []
    @State private var problem: String?
    @State private var dictation = Dictation()
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var takingPhoto = false
    @State private var askingForGroqKey = false
    @FocusState private var focused: Bool

    private struct Attachment: Identifiable {
        var id = UUID()
        /// Set once the photo has been resized.
        var file: StoredFile?
    }

    private var canSend: Bool {
        chat.loaded
            && chat.pending == nil
            && dictation.phase == .idle
            && attachments.allSatisfy { $0.file != nil }
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var body: some View {
        VStack(spacing: 8) {
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            if !attachments.isEmpty {
                attachmentStrip
            }

            HStack(alignment: .bottom, spacing: 8) {
                leadingButton
                field
                microphoneButton
                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
        .animation(.default, value: problem)
        .animation(.default, value: dictation.phase)
        .photosPicker(isPresented: $choosingPhotos, selection: $pickedPhotos, maxSelectionCount: 10, matching: .images)
        .onChange(of: pickedPhotos) { addPicked() }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in
                if let data = image.jpegData(compressionQuality: 0.95) { add([data]) }
            }
            .ignoresSafeArea()
        }
        .alert("Dictation needs a Groq API key", isPresented: $askingForGroqKey) {
            Button("Open Settings", action: openSettings)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add your Groq API key in Settings to dictate messages.")
        }
        .onAppear {
            dictation.onHeard = { insert($0) }
            dictation.onProblem = { show($0) }
        }
        .onDisappear { dictation.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { dictation.interrupt() }
        }
    }

    // MARK: Parts

    @ViewBuilder
    private var leadingButton: some View {
        if dictation.isActive {
            Button {
                dictation.cancel()
            } label: {
                CircleIcon(systemName: "xmark")
            }
            .accessibilityLabel(Text("Cancel"))
        } else {
            Menu {
                Button("Photo Library", systemImage: "photo.on.rectangle") { choosingPhotos = true }
                if CameraPicker.isAvailable {
                    Button("Camera", systemImage: "camera") { takingPhoto = true }
                }
                Button("Paste Image", systemImage: "doc.on.clipboard") { pasteImages() }
            } label: {
                CircleIcon(systemName: "plus")
            }
            .accessibilityLabel(Text("Add photos"))
        }
    }

    @ViewBuilder
    private var field: some View {
        switch dictation.phase {
        case .recording:
            HStack(spacing: 10) {
                Text(verbatim: String(format: "%d:%02d", dictation.seconds / 60, dictation.seconds % 60))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                WaveformView(levels: dictation.levels)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        case .transcribing:
            WorkingLabel(title: "Transcribing", startedAt: dictation.transcribingSince)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        case .idle, .starting:
            HStack(alignment: .bottom, spacing: 4) {
                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.vertical, 9)
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 10)
                    }
                    .accessibilityLabel(Text("Clear text"))
                }
            }
            .padding(.horizontal, 14)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        }
    }

    private var microphoneButton: some View {
        Button {
            if dictation.phase == .idle && settings.groqKey.isEmpty {
                askingForGroqKey = true
            } else {
                dictation.toggle(groqKey: settings.groqKey)
            }
        } label: {
            switch dictation.phase {
            case .starting, .transcribing:
                ProgressView()
                    .frame(width: 38, height: 38)
            case .recording:
                CircleIcon(systemName: "checkmark", prominent: true)
            case .idle:
                CircleIcon(systemName: "mic")
            }
        }
        .disabled(dictation.phase == .starting || dictation.phase == .transcribing)
        .accessibilityLabel(dictation.phase == .recording ? Text("Transcribe") : Text("Dictate"))
    }

    @ViewBuilder
    private var sendButton: some View {
        if chat.pending != nil {
            Button {
                chat.stop()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 34))
            }
            .accessibilityLabel(Text("Stop"))
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
            }
            .disabled(!canSend)
            .accessibilityLabel(Text("Send"))
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let file = attachment.file {
                                StoredImageView(file: file, maxPixelSize: 200, contentMode: .fill)
                            } else {
                                Color(uiColor: .secondarySystemBackground)
                                    .overlay { ProgressView() }
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button {
                            remove(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, Color.black.opacity(0.6))
                                .font(.title3)
                        }
                        .offset(x: 6, y: -6)
                        .accessibilityLabel(Text("Remove photo"))
                    }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
    }

    // MARK: Actions

    private func send() {
        guard canSend else { return }
        chat.send(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            photos: attachments.compactMap(\.file)
        )
        text = ""
        attachments = []
        focused = false
        onSend()
    }

    /// Puts what was dictated after whatever was already written, to be read over before sending.
    private func insert(_ heard: String) {
        if text.isEmpty || text.last?.isWhitespace == true {
            text += heard
        } else {
            text += " " + heard
        }
    }

    private func addPicked() {
        let items = pickedPhotos
        guard !items.isEmpty else { return }
        pickedPhotos = []

        let ids = items.map { _ in UUID() }
        attachments += ids.map { Attachment(id: $0) }
        Task {
            // One at a time: full-size photos use a lot of memory while decoding.
            for (item, id) in zip(items, ids) {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw ImageError.unreadable }
                    finish(id, with: try await ImageProcessing.store(data))
                } catch {
                    remove(id)
                    show(String(localized: "Couldn't read that photo."))
                }
            }
        }
    }

    private func add(_ images: [Data]) {
        let ids = images.map { _ in UUID() }
        attachments += ids.map { Attachment(id: $0) }
        Task {
            for (data, id) in zip(images, ids) {
                do {
                    finish(id, with: try await ImageProcessing.store(data))
                } catch {
                    remove(id)
                    show(String(localized: "Couldn't read that photo."))
                }
            }
        }
    }

    private func pasteImages() {
        let images = UIPasteboard.general.images ?? []
        guard !images.isEmpty else {
            show(String(localized: "There is no image to paste."))
            return
        }
        add(images.compactMap { $0.pngData() })
    }

    private func finish(_ id: UUID, with file: StoredFile) {
        if let index = attachments.firstIndex(where: { $0.id == id }) {
            attachments[index].file = file
        } else {
            // Removed while it was being read.
            BlobStore.delete([file])
        }
    }

    private func remove(_ id: UUID) {
        if let file = attachments.first(where: { $0.id == id })?.file { BlobStore.delete([file]) }
        attachments.removeAll { $0.id == id }
    }

    private func show(_ message: String) {
        problem = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if problem == message { problem = nil }
        }
    }
}

/// A round button face, the size of the text field's single line.
struct CircleIcon: View {
    let systemName: String
    var prominent = false

    var body: some View {
        Image(systemName: systemName)
            .font(.body.weight(.semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(width: 38, height: 38)
            .background(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(uiColor: .secondarySystemBackground)), in: Circle())
    }
}

/// How loud the last stretches of sound were, newest on the right.
struct WaveformView: View {
    let levels: [Double]

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 5
            let count = min(levels.count, Int(size.width / step))
            for (index, level) in levels.suffix(count).enumerated() {
                let height = max(3, CGFloat(level) * size.height)
                let x = size.width - CGFloat(count - index) * step
                let bar = CGRect(x: x, y: (size.height - height) / 2, width: 3, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(.accentColor))
            }
        }
        .frame(height: 26)
        .accessibilityHidden(true)
    }
}
