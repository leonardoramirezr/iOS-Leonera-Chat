import Foundation
import Observation

/// What the app is told to do: the API keys, kept in the Keychain, and the models.
@MainActor
@Observable
final class SettingsStore {
    private var storedAPIKey = Keychain.read(Keys.openAI)
    private var storedGroqKey = Keychain.read(Keys.groq)
    private var storedTextModel = UserDefaults.standard.string(forKey: Keys.textModel) ?? "gpt-5"
    private var storedImageModel = UserDefaults.standard.string(forKey: Keys.imageModel) ?? "gpt-image-2.5-sunburst"
    /// A copy of what `/v1/models` answers, asked for again whenever the key changes.
    private var storedModels = UserDefaults.standard.stringArray(forKey: Keys.models) ?? []

    @ObservationIgnored private var modelsRefreshed = false

    private enum Keys {
        static let openAI = "openai-api-key"
        static let groq = "groq-api-key"
        static let textModel = "text-model"
        static let imageModel = "image-model"
        static let models = "models"
    }

    var apiKey: String {
        get { storedAPIKey }
        set {
            storedAPIKey = newValue
            Keychain.write(newValue, for: Keys.openAI)
        }
    }

    /// Dictation goes through Groq, whose key is not OpenAI's.
    var groqKey: String {
        get { storedGroqKey }
        set {
            storedGroqKey = newValue
            Keychain.write(newValue, for: Keys.groq)
        }
    }

    var textModel: String {
        get { storedTextModel }
        set {
            storedTextModel = newValue
            UserDefaults.standard.set(newValue, forKey: Keys.textModel)
        }
    }

    var imageModel: String {
        get { storedImageModel }
        set {
            storedImageModel = newValue
            UserDefaults.standard.set(newValue, forKey: Keys.imageModel)
        }
    }

    var availableModels: [String] {
        get { storedModels }
        set {
            storedModels = newValue
            UserDefaults.standard.set(newValue, forKey: Keys.models)
        }
    }

    var textModelOptions: [String] { ModelCatalog.textOptions(availableModels, current: textModel) }
    var imageModelOptions: [String] { ModelCatalog.imageOptions(availableModels, current: imageModel) }

    /// Refreshes the list of models once per launch, in case new ones became available.
    func refreshModels() async {
        guard !modelsRefreshed, !apiKey.isEmpty else { return }
        modelsRefreshed = true
        do {
            availableModels = try await OpenAIClient(apiKey: apiKey).modelIDs()
        } catch {
            modelsRefreshed = false
        }
    }

    /// Checks the OpenAI key and keeps it. Throws when OpenAI rejects it or can't be reached.
    func signIn(with key: String) async throws {
        do {
            let models = try await OpenAIClient(apiKey: key).modelIDs()
            availableModels = models
            modelsRefreshed = true
        } catch let error as APIError where error.status == 401 || error.status == 0 {
            throw error
        } catch {
            // Restricted keys may not be allowed to list models but can still create responses.
        }
        apiKey = key
    }

    /// Checks the Groq key and keeps it.
    func saveGroqKey(_ key: String) async throws {
        do {
            try await GroqClient(apiKey: key).checkKey()
        } catch let error as APIError where error.status == 401 || error.status == 0 {
            throw error
        } catch {
            // A key that may not list the models may still transcribe.
        }
        groqKey = key
    }
}

enum ModelCatalog {
    /// Models documented as supporting the image generation tool, shown until the key's own list loads.
    private static let suggestedText = [
        "gpt-5.5", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.2", "gpt-5", "gpt-5-nano", "o3",
        "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-mini",
    ]

    private static let suggestedImage = [
        "gpt-image-2.5-sunburst", "gpt-image-2.5-flare", "gpt-image-2", "gpt-image-1.5", "gpt-image-1",
        "gpt-image-1-mini",
    ]

    private static let snapshot = #"-\d{4}-\d{2}-\d{2}$"#
    private static let notAChatModel =
        #"image|audio|realtime|tts|transcribe|search|embedding|moderation|instruct|codex|oss|diarize|deep-research|computer-use|chat-latest"#

    static func textOptions(_ ids: [String], current: String) -> [String] {
        let models = ids.filter {
            matches($0, #"^(gpt-\d|o\d)"#) && !matches($0, snapshot) && !matches($0, notAChatModel)
        }
        return withCurrent(models.isEmpty ? suggestedText : models, current)
    }

    static func imageOptions(_ ids: [String], current: String) -> [String] {
        let models = ids.filter { matches($0, #"^(chatgpt-)?gpt-image"#) && !matches($0, snapshot) }
        return withCurrent(models.isEmpty ? suggestedImage : models, current)
    }

    private static func matches(_ id: String, _ pattern: String) -> Bool {
        id.range(of: pattern, options: .regularExpression) != nil
    }

    private static func withCurrent(_ models: [String], _ current: String) -> [String] {
        models.contains(current) ? models : [current] + models
    }
}
