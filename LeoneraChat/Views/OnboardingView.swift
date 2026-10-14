import SwiftUI

struct OnboardingView: View {
    @Environment(SettingsStore.self) private var settings

    @State private var key = ""
    @State private var checking = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                AppLogo(size: 88)
                    .padding(.top, 48)

                VStack(spacing: 10) {
                    Text("Welcome to Leonera Chat")
                        .font(.largeTitle.bold())
                    Text("Chat, and create and edit images from your photos, with OpenAI. Enter your OpenAI API key to get started.")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 8) {
                    Text("OpenAI API key")
                        .font(.subheadline.weight(.medium))
                    SecureField("sk-…", text: $key)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.continue)
                        .focused($focused)
                        .onSubmit(submit)
                        .padding(14)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Button(action: submit) {
                    ZStack {
                        Text("Continue").opacity(checking ? 0 : 1)
                        if checking { ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(checking || trimmedKey.isEmpty)

                VStack(spacing: 6) {
                    Text("Your key is stored in this device's Keychain and is only sent to api.openai.com.")
                    Link("Get an API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                        .fontWeight(.medium)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func submit() {
        let value = trimmedKey
        guard !value.isEmpty, !checking else { return }
        checking = true
        problem = nil
        Task {
            do {
                try await settings.signIn(with: value)
            } catch let error as APIError where error.status == 401 {
                problem = String(localized: "OpenAI rejected this API key.")
            } catch {
                problem = String(localized: "Couldn't reach OpenAI. Check your connection and try again.")
            }
            checking = false
        }
    }
}

/// The app's icon, as shown inside the app.
struct AppLogo: View {
    var size: CGFloat

    var body: some View {
        Image("Logo")
            .resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
            .accessibilityHidden(true)
    }
}
