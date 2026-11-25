import AVFoundation
import Speech

/// On-device speech recognition, run only while the switcher's list is open.
/// Reports the running transcript; never acts on its own.
final class Voice {
    var onTranscript: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var authorized = false

    var isListening: Bool { task != nil }

    /// Asked at launch so the prompts don't appear mid-switch. Requires the
    /// usage descriptions in Info.plist, so it's skipped under `swift run`.
    func requestPermission() {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else { return }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { self?.authorized = granted }
            }
        }
    }

    /// `hints` are the visible titles, which bias recognition toward them.
    func start(hints: [String]) {
        guard authorized, task == nil, let recognizer, recognizer.isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.contextualStrings = Array(hints.prefix(100))

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return
        }
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            DispatchQueue.main.async { self?.onTranscript?(text) }
        }
    }

    func stop() {
        guard task != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }
}
