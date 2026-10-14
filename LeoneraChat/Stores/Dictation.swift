import Foundation
import Observation

/// Bars of the waveform, each standing for a tenth of a second.
let waveformBars = 60

/// The microphone next to the send button. A tap opens it, a second one sends what it heard to Whisper,
/// and the text goes into the message being written, to be read over before it is sent.
@MainActor
@Observable
final class Dictation {
    enum Phase {
        case idle, starting, recording, transcribing
    }

    private(set) var phase: Phase = .idle
    /// Seconds the microphone has been open.
    private(set) var seconds = 0
    /// When the recording went to Whisper.
    private(set) var transcribingSince = Date()
    /// How loud each of the last stretches of sound was, from 0 to 1, oldest first.
    private(set) var levels = Array(repeating: 0.0, count: waveformBars)

    /// Longer than anyone dictates a message: a microphone left open closes itself and transcribes.
    private static let maxSeconds: TimeInterval = 180
    /// Shorter than this is two taps in a row, not something said.
    private static let minSeconds: TimeInterval = 0.6

    @ObservationIgnored private var recorder: AudioRecorder?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var openedAt = Date()
    /// Goes up with every dictation, so one cancelled on the way knows it is no longer wanted.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var groqKey = ""

    /// What was said, as text. Never empty.
    @ObservationIgnored var onHeard: (String) -> Void = { _ in }
    /// Why nothing came of it, to tell the user.
    @ObservationIgnored var onProblem: (String) -> Void = { _ in }

    var isActive: Bool { phase == .recording || phase == .transcribing }

    /// The microphone button: opens it, or closes it and transcribes what it heard.
    func toggle(groqKey: String) {
        switch phase {
        case .idle:
            self.groqKey = groqKey
            open()
        case .recording:
            finish()
        case .starting, .transcribing:
            break
        }
    }

    /// Closes the microphone, or drops the transcription under way, and throws away what it heard.
    func cancel() {
        generation += 1
        work?.cancel()
        ticker?.cancel()
        recorder?.cancel()
        recorder = nil
        phase = .idle
    }

    /// iOS stops the microphone of an app sent to the background: what was said so far is transcribed.
    func interrupt() {
        if phase == .recording { finish() }
    }

    private func open() {
        generation += 1
        let current = generation
        phase = .starting

        work = Task {
            do {
                let recorder = try await AudioRecorder.start()
                guard generation == current else {
                    recorder.cancel()
                    return
                }
                self.recorder = recorder
                seconds = 0
                levels = Array(repeating: 0, count: waveformBars)
                openedAt = Date()
                phase = .recording
                startTicker()
            } catch {
                guard generation == current else { return }
                phase = .idle
                onProblem(Self.describe(error))
            }
        }
    }

    /// While recording: the clock, the waveform and the time limit.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task {
            var peak = 0.0
            var barAt = Date()
            while !Task.isCancelled, phase == .recording, let recorder {
                let elapsed = Date().timeIntervalSince(openedAt)
                seconds = Int(elapsed)
                // A bar keeps the loudest moment of its stretch, so no syllable falls between two of them.
                peak = max(peak, recorder.level())
                if Date().timeIntervalSince(barAt) >= 0.1 {
                    levels = Array(levels.dropFirst()) + [peak]
                    peak = 0
                    barAt = Date()
                }
                if elapsed >= Self.maxSeconds {
                    finish()
                    return
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func finish() {
        guard phase == .recording, let recorder else { return }
        let current = generation
        let duration = Date().timeIntervalSince(openedAt)
        ticker?.cancel()
        self.recorder = nil
        transcribingSince = Date()
        phase = .transcribing

        let audio = recorder.stop()
        let client = GroqClient(apiKey: groqKey)
        work = Task {
            var heard = ""
            var problem = ""
            do {
                if duration >= Self.minSeconds {
                    heard = try await client.transcribe(audio: audio, language: Self.language)
                }
                if heard.isEmpty { problem = String(localized: "Nothing was heard.") }
            } catch {
                problem = Self.describe(error)
            }
            try? FileManager.default.removeItem(at: audio)

            // Cancelled on the way, which already put everything back: another one may even have begun.
            guard generation == current else { return }
            phase = .idle
            if problem.isEmpty { onHeard(heard) } else { onProblem(problem) }
        }
    }

    /// The app's language: a short message is too little for Whisper to tell it.
    private static var language: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("es") == true ? "es" : "en"
    }

    /// What to tell the user when dictating fails.
    private static func describe(_ error: Error) -> String {
        if let error = error as? MicrophoneError { return error.localizedDescription }
        guard let error = error as? APIError else { return String(localized: "Something went wrong.") }

        switch error.status {
        case 0: return String(localized: "Couldn't reach Groq. Check your connection and try again.")
        case 401: return String(localized: "Groq rejected the API key. Change it in Settings.")
        case 429: return String(localized: "Groq asks you to wait: your API key has reached its usage limit for now.")
        case 413: return String(localized: "The recording is too long.")
        default: return error.message
        }
    }
}
