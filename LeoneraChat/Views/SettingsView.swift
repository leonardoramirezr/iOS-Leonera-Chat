import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings

    @State private var groqDraft = ""
    @State private var checkingGroq = false
    @State private var groqProblem: String?
    @State private var confirmingKeyChange = false
    @State private var confirmingGroqKeyChange = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Models") {
                ModelPicker(title: "Text model", selection: $settings.textModel, options: settings.textModelOptions)
                ModelPicker(title: "Image model", selection: $settings.imageModel, options: settings.imageModelOptions)
                LabeledContent("Speech to text") {
                    Text(verbatim: GroqClient.transcriptionModel)
                }
            }

            Section("OpenAI API key") {
                LabeledContent("Key") {
                    Text(verbatim: masked(settings.apiKey)).monospaced()
                }
                Button("Change API key", role: .destructive) { confirmingKeyChange = true }
            }

            Section {
                if settings.groqKey.isEmpty {
                    SecureField("gsk_…", text: $groqDraft)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(saveGroqKey)
                    Button(action: saveGroqKey) {
                        HStack {
                            Text("Save")
                            if checkingGroq {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(checkingGroq || groqDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    LabeledContent("Key") {
                        Text(verbatim: masked(settings.groqKey)).monospaced()
                    }
                    Button("Change API key", role: .destructive) { confirmingGroqKeyChange = true }
                }
            } header: {
                Text("Groq API key")
            } footer: {
                if settings.groqKey.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if let groqProblem {
                            Text(groqProblem).foregroundStyle(.red)
                        }
                        Text("Used to dictate messages. It is stored in this device's Keychain and only sent to api.groq.com, along with your recordings.")
                        Link("Get an API key", destination: URL(string: "https://console.groq.com/keys")!)
                    }
                }
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(verbatim: Self.version)
                }
            }
        }
        .navigationTitle("Settings")
        .task { await settings.refreshModels() }
        .confirmationDialog(
            "Remove the OpenAI API key saved on this device?",
            isPresented: $confirmingKeyChange,
            titleVisibility: .visible
        ) {
            Button("Remove API key", role: .destructive) { settings.apiKey = "" }
        }
        .confirmationDialog(
            "Remove the Groq API key saved on this device?",
            isPresented: $confirmingGroqKeyChange,
            titleVisibility: .visible
        ) {
            Button("Remove API key", role: .destructive) {
                groqDraft = ""
                groqProblem = nil
                settings.groqKey = ""
            }
        }
    }

    private func masked(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "•", count: key.count) }
        return "\(key.prefix(7))…\(key.suffix(4))"
    }

    private func saveGroqKey() {
        let value = groqDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !checkingGroq else { return }

        // An OpenAI key is no good to Groq, and not Groq's to see.
        if value.hasPrefix("sk-") {
            groqProblem = String(localized: "That looks like an OpenAI API key. Groq uses its own, which start with gsk_.")
            return
        }

        checkingGroq = true
        groqProblem = nil
        Task {
            do {
                try await settings.saveGroqKey(value)
                groqDraft = ""
            } catch let error as APIError where error.status == 401 {
                groqProblem = String(localized: "Groq rejected this API key.")
            } catch {
                groqProblem = String(localized: "Couldn't reach Groq. Check your connection and try again.")
            }
            checkingGroq = false
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// One of the models the key can use, or any other one typed in.
private struct ModelPicker: View {
    let title: LocalizedStringKey
    @Binding var selection: String
    let options: [String]

    @State private var enteringCustom = false
    @State private var custom = ""

    /// Model IDs never contain spaces, so this can't clash with one.
    private static let customTag = "custom model"

    var body: some View {
        Picker(title, selection: choice) {
            ForEach(options, id: \.self) { option in
                Text(verbatim: option).tag(option)
            }
            Text("Custom…").tag(Self.customTag)
        }
        .alert(title, isPresented: $enteringCustom) {
            TextField("Model ID", text: $custom)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let id = custom.trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty { selection = id }
            }
        } message: {
            Text("The ID of any OpenAI model, as in the API.")
        }
    }

    private var choice: Binding<String> {
        Binding {
            selection
        } set: { value in
            if value == Self.customTag {
                custom = ""
                enteringCustom = true
            } else {
                selection = value
            }
        }
    }
}
