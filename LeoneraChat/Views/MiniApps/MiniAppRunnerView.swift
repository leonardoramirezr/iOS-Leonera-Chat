import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Runs a mini app: the answers to its questions, the files it asks for, and the one result.
struct MiniAppRunnerView: View {
    let appID: UUID

    @Environment(MiniAppStore.self) private var miniApps
    @Environment(RunStore.self) private var runs
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var editing: EditorTarget?
    @State private var confirmingStartOver = false
    @State private var viewing: StoredFile?
    @State private var problem: String?
    @FocusState private var focusedQuestion: String?

    /// The field a picker was opened for.
    @State private var target: MiniAppInput?
    @State private var choosingPhotos = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var takingPhoto = false
    @State private var choosingFiles = false

    var body: some View {
        Group {
            if let app = miniApps.app(appID) {
                content(app)
            } else {
                ContentUnavailableView("This mini app was deleted.", systemImage: "trash")
            }
        }
        .onChange(of: miniApps.app(appID) == nil) { _, deleted in
            if deleted { dismiss() }
        }
    }

    private func content(_ app: MiniApp) -> some View {
        ScrollViewReader { proxy in
            form(app, proxy)
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editing = EditorTarget(app: app) }
            }
        }
        .sheet(item: $editing) { target in
            MiniAppEditorView(app: target.app)
        }
        .confirmationDialog(
            "Clear the answers, the files and the result?",
            isPresented: $confirmingStartOver,
            titleVisibility: .visible
        ) {
            Button("Start over", role: .destructive) { runs.clear(app.id) }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $pickedPhotos, maxSelectionCount: 10, matching: .images)
        .onChange(of: pickedPhotos) { addPicked(app) }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in
                takePhoto(app, image)
            }
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $choosingFiles,
            allowedContentTypes: target?.kind == .image ? [.image] : [.item],
            allowsMultipleSelection: true
        ) { result in
            importFiles(app, result)
        }
        .fullScreenCover(item: $viewing) { file in
            ImageViewer(file: file)
        }
    }

    @ViewBuilder
    private func form(_ app: MiniApp, _ proxy: ScrollViewProxy) -> some View {
        let run = runs.run(app.id)
        let running = runs.isRunning(app.id)

        Form {
            ForEach(app.questions, id: \.self) { question in
                Section {
                    TextField("Your answer", text: answer(app.id, question), axis: .vertical)
                        .lineLimit(2...10)
                        .focused($focusedQuestion, equals: question)
                } header: {
                    Text(verbatim: question)
                }
            }

            ForEach(app.inputs) { input in
                Section {
                    files(app, input, run.files[input.id] ?? [])
                } header: {
                    Text(verbatim: input.title.isEmpty ? defaultTitle(input) : input.title)
                }
            }

            if app.questions.isEmpty && app.inputs.isEmpty {
                Section {
                    Text("No questions yet: it will be sent as it is.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if running {
                    Button(role: .destructive) {
                        runs.stop(app.id)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        send(app, proxy)
                    } label: {
                        Label("Run", systemImage: "paperplane.fill")
                            .fontWeight(.semibold)
                    }
                    .disabled(runs.isReading(app))
                }
                Button("Start over", role: .destructive) { confirmingStartOver = true }
                    .disabled(run.isEmpty)
            } footer: {
                if let problem {
                    Text(problem).foregroundStyle(.red)
                }
            }

            if let result = run.result {
                Section("Result") {
                    MessageView(
                        message: result,
                        onView: { viewing = $0 },
                        onRetry: { runs.retry(app) },
                        onUpdateKey: { settings.apiKey = "" }
                    )
                    .padding(.vertical, 6)
                }
                .id("result")
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func files(_ app: MiniApp, _ input: MiniAppInput, _ files: [PickedFile]) -> some View {
        ForEach(files) { file in
            HStack(spacing: 12) {
                if file.isImage, let stored = file.stored {
                    Button {
                        viewing = stored
                    } label: {
                        StoredImageView(file: stored, maxPixelSize: 160, contentMode: .fill)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "doc.text")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                Text(verbatim: file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .onDelete { offsets in
            for index in offsets { runs.remove(files[index], from: app.id, input: input.id) }
        }

        ForEach(0..<(runs.reading[input.id] ?? 0), id: \.self) { _ in
            HStack(spacing: 12) {
                ProgressView()
                    .frame(width: 44, height: 44)
                Text("Reading…")
                    .foregroundStyle(.secondary)
            }
        }

        Menu {
            if input.kind == .image {
                Button("Photo Library", systemImage: "photo.on.rectangle") {
                    target = input
                    choosingPhotos = true
                }
                if CameraPicker.isAvailable {
                    Button("Camera", systemImage: "camera") {
                        target = input
                        takingPhoto = true
                    }
                }
            }
            Button("Files", systemImage: "folder") {
                target = input
                choosingFiles = true
            }
        } label: {
            Label(
                input.kind == .image ? LocalizedStringKey("Add images") : LocalizedStringKey("Add files"),
                systemImage: input.kind == .image ? "photo.badge.plus" : "doc.badge.plus"
            )
        }
    }

    private func defaultTitle(_ input: MiniAppInput) -> String {
        input.kind == .image ? String(localized: "Image") : String(localized: "File")
    }

    private func answer(_ app: UUID, _ question: String) -> Binding<String> {
        Binding(
            get: { runs.answer(app, question) },
            set: { runs.setAnswer(app, question, $0) }
        )
    }

    private func send(_ app: MiniApp, _ proxy: ScrollViewProxy) {
        focusedQuestion = nil
        runs.send(app)
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation { proxy.scrollTo("result", anchor: .top) }
        }
    }

    private func takePhoto(_ app: MiniApp, _ image: UIImage) {
        guard let input = target, let data = image.jpegData(compressionQuality: 0.95) else { return }
        read(app, input, count: 1) { _ in
            try FileReading.image(data, name: "photo.jpg")
        }
    }

    private func importFiles(_ app: MiniApp, _ result: Result<[URL], Error>) {
        guard let input = target, case .success(let urls) = result, !urls.isEmpty else { return }
        read(app, input, count: urls.count) { index in
            try FileReading.read(urls[index])
        }
    }

    private func addPicked(_ app: MiniApp) {
        let items = pickedPhotos
        guard let input = target, !items.isEmpty else { return }
        pickedPhotos = []
        read(app, input, count: items.count) { index in
            guard let data = try await items[index].loadTransferable(type: Data.self) else {
                throw FileReadingError.unreadable
            }
            return try FileReading.image(data, name: "photo-\(index + 1).jpg")
        }
    }

    /// Reads the picked files one at a time (full-size photos use a lot of memory while decoding), each
    /// shown as being read until it is ready.
    private func read(
        _ app: MiniApp,
        _ input: MiniAppInput,
        count: Int,
        _ reading: @escaping @Sendable (Int) async throws -> PickedFile
    ) {
        runs.beginReading(input.id, count: count)
        Task {
            for index in 0..<count {
                do {
                    let file = try await Task.detached { try await reading(index) }.value
                    runs.add(file, to: app.id, input: input.id)
                } catch FileReadingError.tooLarge {
                    show(String(localized: "That file is too large: 25 MB at most."))
                } catch {
                    show(String(localized: "Couldn't read that file."))
                }
                runs.endReading(input.id)
            }
        }
    }

    private func show(_ message: String) {
        problem = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if problem == message { problem = nil }
        }
    }
}
