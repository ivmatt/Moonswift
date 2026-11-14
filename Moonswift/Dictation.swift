import AVFAudio
import Speech

/// Search by voice: listens with the microphone and keeps `text` to what it has heard so far, on the device where
/// it can. Stops when told to, once the words are final, or after a moment of quiet.
@Observable final class Dictation {
    private(set) var isListening = false
    private(set) var text = ""
    @ObservationIgnored private var session: SpeechSession?
    @ObservationIgnored private var quiet: Task<Void, Never>?

    /// Starts listening, or says why it can't.
    func start() async -> String? {
        guard !isListening else { return nil }
        guard await SpeechSession.authorize() else {
            return "Moonswift needs the microphone and speech recognition to search by voice. You can allow them in Settings."
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return "Dictation isn't available right now." }
        do {
            session = try SpeechSession(recognizer: recognizer) { [weak self] heard, isFinal in
                Task { @MainActor in self?.heard(heard, isFinal: isFinal) }
            }
        } catch {
            return "Couldn't start dictation: \(error.localizedDescription)"
        }
        text = ""
        isListening = true
        stopWhenQuiet(after: .seconds(5)) // nothing said at all
        return nil
    }

    func stop() {
        quiet?.cancel()
        session?.stop()
        session = nil
        isListening = false
    }

    private func heard(_ words: String?, isFinal: Bool) {
        guard isListening else { return }
        if let words { text = words }
        if isFinal { stop() } else { stopWhenQuiet(after: .seconds(1.5)) }
    }

    private func stopWhenQuiet(after delay: Duration) {
        quiet?.cancel()
        quiet = Task {
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { stop() }
        }
    }
}

/// The microphone and recognizer for one dictation. Off the main actor: the microphone and recognizer call back on
/// their own threads.
private nonisolated final class SpeechSession: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?

    static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// `onResult` gets the words so far (nil on an error) and whether they're final.
    init(recognizer: SFSpeechRecognizer, onResult: @escaping @Sendable (String?, Bool) -> Void) throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audio.setActive(true, options: .notifyOthersOnDeactivation)
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true } // stays on the device
        let request = request
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
        engine.prepare()
        try engine.start()
        task = recognizer.recognitionTask(with: request) { result, error in
            if let result { onResult(result.bestTranscription.formattedString, result.isFinal) }
            else if error != nil { onResult(nil, true) }
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request.endAudio()
        task?.cancel()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
