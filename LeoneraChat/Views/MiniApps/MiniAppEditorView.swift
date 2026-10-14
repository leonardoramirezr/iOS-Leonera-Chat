import SwiftUI

/// Sets up a mini app: its name, the prompt with its questions, and the files and images it asks for.
struct MiniAppEditorView: View {
    /// The mini app to edit; none for a new one.
    let app: MiniApp?
    var onSave: (UUID) -> Void = { _ in }

    @Environment(MiniAppStore.self) private var miniApps
    @Environment(RunStore.self) private var runs
    @Environment(\.dismiss) private var dismiss

    // A copy: nothing changes until it is saved.
    @State private var name: String
    @State private var prompt: String
    @State private var inputs: [MiniAppInput]

    @State private var confirmingDiscard = false
    @State private var confirmingDelete = false
    @State private var addingQuestion = false
    @State private var newQuestion = ""

    init(app: MiniApp?, onSave: @escaping (UUID) -> Void = { _ in }) {
        self.app = app
        self.onSave = onSave
        _name = State(initialValue: app?.name ?? "")
        _prompt = State(initialValue: app?.prompt ?? "")
        _inputs = State(initialValue: app?.inputs ?? [])
    }

    private var questions: [String] { MiniAppPrompt.questions(in: prompt) }
    private var canSave: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var dirty: Bool {
        name != (app?.name ?? "") || prompt != (app?.prompt ?? "") || inputs != (app?.inputs ?? [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Mini app", text: $name)
                }

                Section {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 180)
                        .autocorrectionDisabled()
                        .overlay(alignment: .topLeading) {
                            if prompt.isEmpty {
                                Text("Write a cover letter for this job:\n[[[Job posting]]]\nIn this tone:\n[[[Tone]]]")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                    Button {
                        newQuestion = ""
                        addingQuestion = true
                    } label: {
                        Label("Add question", systemImage: "plus.bubble")
                    }
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("Write [[[question]]] wherever you want to be asked something: your answer goes right after it.")
                }

                Section("Questions") {
                    if questions.isEmpty {
                        Text("No questions yet: it will be sent as it is.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(questions, id: \.self) { question in
                            Label(question, systemImage: "questionmark.bubble")
                        }
                    }
                }

                Section {
                    ForEach($inputs) { $input in
                        HStack(spacing: 12) {
                            Picker("Kind", selection: $input.kind) {
                                Label("Image", systemImage: "photo").tag(MiniAppInput.Kind.image)
                                Label("File", systemImage: "doc").tag(MiniAppInput.Kind.file)
                            }
                            .labelsHidden()
                            .fixedSize()
                            TextField("Title or question", text: $input.title)
                        }
                    }
                    .onDelete { inputs.remove(atOffsets: $0) }

                    Menu {
                        Button("Image", systemImage: "photo") { inputs.append(MiniAppInput(kind: .image)) }
                        Button("File", systemImage: "doc") { inputs.append(MiniAppInput(kind: .file)) }
                    } label: {
                        Label("Add field", systemImage: "plus")
                    }
                } header: {
                    Text("Files and images")
                } footer: {
                    Text("Fields to add files or images when running it. Each one is sent with its title.")
                }

                if app != nil {
                    Section {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Delete mini app", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(app == nil ? LocalizedStringKey("New mini app") : LocalizedStringKey("Edit mini app"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if dirty { confirmingDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
            .interactiveDismissDisabled(dirty)
            .confirmationDialog("Discard your changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
            }
            .confirmationDialog(
                "Delete this mini app? Its last result will be deleted too.",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete mini app", role: .destructive, action: delete)
            }
            .alert("Add question", isPresented: $addingQuestion) {
                TextField("Question", text: $newQuestion)
                Button("Cancel", role: .cancel) {}
                Button("Add", action: insertQuestion)
            } message: {
                Text("It is asked every time the mini app runs, and the answer goes right after it in the prompt.")
            }
        }
    }

    private func save() {
        guard canSave else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? String(localized: "Mini app") : trimmedName
        let finalInputs = inputs.map { input in
            var input = input
            input.title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return input
        }

        if let app {
            miniApps.update(app.id, name: finalName, prompt: prompt, inputs: finalInputs)
            onSave(app.id)
        } else {
            onSave(miniApps.add(name: finalName, prompt: prompt, inputs: finalInputs).id)
        }
        dismiss()
    }

    private func delete() {
        guard let app else { return }
        runs.forget(app.id)
        miniApps.remove(app.id)
        dismiss()
    }

    /// Adds the question at the end of the prompt, on a line of its own.
    private func insertQuestion() {
        let question = newQuestion
            .components(separatedBy: CharacterSet(charactersIn: "[]\n"))
            .joined()
            .trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else { return }
        let separator = prompt.isEmpty || prompt.hasSuffix("\n") ? "" : "\n"
        prompt += "\(separator)[[[\(question)]]]"
    }
}
