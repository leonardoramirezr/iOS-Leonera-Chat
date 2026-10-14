import AVFoundation
import UIKit

enum MicrophoneError: LocalizedError {
    case denied
    case failed

    var errorDescription: String? {
        switch self {
        case .denied: String(localized: "No permission to use the microphone. Allow it in Settings.")
        case .failed: String(localized: "Couldn't open the microphone.")
        }
    }
}

/// The microphone, recorded to an m4a file. It is only open while dictating: kept open, it would leave
/// the microphone indicator on and the battery draining.
@MainActor
final class AudioRecorder {
    private let recorder: AVAudioRecorder
    let url: URL

    private init(recorder: AVAudioRecorder, url: URL) {
        self.recorder = recorder
        self.url = url
    }

    static func start() async throws -> AudioRecorder {
        guard await AVAudioApplication.requestRecordPermission() else { throw MicrophoneError.denied }

        let session = AVAudioSession.sharedInstance()
        let url = FileManager.default.temporaryDirectory.appending(path: "dictation-\(UUID().uuidString).m4a")
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw MicrophoneError.failed }

            // A long message dictated without touching the phone would otherwise let it lock.
            UIApplication.shared.isIdleTimerDisabled = true
            return AudioRecorder(recorder: recorder, url: url)
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw MicrophoneError.failed
        }
    }

    /// How loud the microphone is right now, from 0 to 1.
    func level() -> Double {
        recorder.updateMeters()
        let amplitude = pow(10, Double(recorder.averagePower(forChannel: 0)) / 20)
        // Speech rarely goes past a quarter of full scale: stretched so it fills the meter.
        return min(1, amplitude * 4)
    }

    /// Closes the microphone and hands over what it heard.
    func stop() -> URL {
        recorder.stop()
        release()
        return url
    }

    /// Closes the microphone and throws away what it heard.
    func cancel() {
        recorder.stop()
        recorder.deleteRecording()
        release()
    }

    private func release() {
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
