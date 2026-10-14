import Foundation

/// A field to add files or images when running a mini app.
struct MiniAppInput: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case image, file
    }

    var id = UUID()
    var kind: Kind
    var title = ""
}

/// A prompt that asks before it is sent, run for one result.
struct MiniApp: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// With a `[[[question]]]` wherever the user is asked something.
    var prompt: String
    /// The files and images it asks for, after the questions.
    var inputs: [MiniAppInput]
    var createdAt = Date()

    var questions: [String] { MiniAppPrompt.questions(in: prompt) }
}

enum MiniAppPrompt {
    /// A question: anything between three brackets on each side, on one line.
    private static let question = try! NSRegularExpression(pattern: #"\[\[\[([^\[\]\n]+)\]\]\]"#)

    /// The questions a prompt asks, in order. The same question asked twice is one field.
    static func questions(in prompt: String) -> [String] {
        let range = NSRange(prompt.startIndex..., in: prompt)
        var seen = Set<String>()
        return question.matches(in: prompt, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: prompt) else { return nil }
            let text = prompt[range].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, seen.insert(text).inserted else { return nil }
            return text
        }
    }

    /// The prompt with every answer written right under the question it answers.
    static func fill(_ prompt: String, answers: [String: String]) -> String {
        var result = prompt
        let matches = question.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: prompt), let inner = Range(match.range(at: 1), in: prompt) else {
                continue
            }
            let key = prompt[inner].trimmingCharacters(in: .whitespaces)
            let answer = answers[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !answer.isEmpty, let target = Range(match.range, in: result) else { continue }
            result.replaceSubrange(target, with: "\(prompt[whole])\n\(answer)")
        }
        return result
    }
}

/// Running a mini app: what the user answered and picked, and the one result it gives.
struct Run: Codable, Hashable {
    /// By question.
    var answers: [String: String] = [:]
    /// By the id of the input they were picked for.
    var files: [UUID: [PickedFile]] = [:]
    var result: Message?

    var isEmpty: Bool {
        result == nil
            && answers.values.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && files.values.allSatisfy(\.isEmpty)
    }

    /// Every stored file the run refers to.
    var storedFiles: [StoredFile] {
        files.values.flatMap { $0.compactMap(\.stored) } + (result?.files ?? [])
    }
}

/// The mini app's prompt, with the answers in it, is what the model is told to do; the files follow in
/// the user's message, each after the title of the field it was picked in.
enum MiniAppRequest {
    static func make(app: MiniApp, run: Run, model: String, imageModel: String) async -> ResponseRequest {
        let answers = Dictionary(uniqueKeysWithValues: app.questions.map { ($0, run.answers[$0] ?? "") })
        var content: [InputContent] = []

        for input in app.inputs {
            let files = run.files[input.id] ?? []
            guard !files.isEmpty else { continue }

            let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { content.append(.text("\(title):")) }
            for file in files {
                if let text = file.text {
                    content.append(.text("\(file.name):\n\n\(text)"))
                } else if let stored = file.stored, let url = try? BlobStore.dataURL(for: stored) {
                    content.append(file.isImage ? .image(url) : .file(name: file.name, data: url))
                }
            }
        }

        if content.isEmpty { content.append(.text("Go ahead.")) }

        return ResponseRequest(
            model: model,
            tools: [.init(model: imageModel)],
            input: [
                .system("\(systemPrompt())\n\n\(MiniAppPrompt.fill(app.prompt, answers: answers))"),
                .user(content),
            ]
        )
    }

    private static func systemPrompt() -> String {
        "You are Leonera Chat, running a mini app: a task the user set up once and runs with new inputs. "
            + "There is no conversation: reply with the finished result only, never with questions or offers to continue. "
            + "The instructions below are the task. Wherever the user was asked something, the question appears between "
            + "triple brackets, like [[[question]]], and the user’s answer is written on the lines right after it; "
            + "a question with nothing after it was left unanswered. "
            + "Files and images the user picked come in their message, each after the title of the field it was picked in. "
            + "Reply in the language of the instructions, unless they ask for another. "
            + "Use Markdown when it improves readability. "
            + "Current date: \(PromptDate.today()). "
            + "You can create and edit images with your image generation tool: use it whenever the task asks for an image. "
            + "Generated images are shown to the user automatically: never include links or Markdown images for them.\n\n"
            + "Instructions:"
    }
}
