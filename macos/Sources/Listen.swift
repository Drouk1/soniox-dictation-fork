import AVFoundation
import Speech

/// Lowercased, accent-free, letters and digits only, single spaces: "Hey, Claude!" → "hey claude".
func normalized(_ text: String) -> String {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    return folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
        .split(separator: " ").joined(separator: " ")
}

func containsWakePhrase(_ text: String) -> Bool {
    let heard = " \(normalized(text)) "
    return items("wakeWords").map(normalized).contains { !$0.isEmpty && heard.contains(" \($0) ") }
}

/// Keeps the mic open while idle and listens for a double clap and/or the wake phrase.
/// The wake phrase is recognised on this Mac; no audio leaves it until dictation starts.
final class IdleListener {
    var onClap: (() -> Void)?
    var onWake: (() -> Void)?
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var claps = false
    private var wake = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var refresh: Timer?

    func start(claps: Bool, wake: Bool) {
        if engine != nil, self.claps == claps, self.wake == wake { return }
        stop()
        guard claps || wake else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        var detector = ClapDetector()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            if claps, let samples = buffer.floatChannelData?[0],
               detector.feed(samples, count: Int(buffer.frameLength), rate: format.sampleRate) {
                DispatchQueue.main.async { self.onClap?() }
            }
            if wake {
                lock.lock()
                let request = request
                lock.unlock()
                request?.append(buffer)
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return log("Idle listener failed: \(error.localizedDescription)")
        }
        self.engine = engine
        self.claps = claps
        self.wake = wake
        if wake { startRecognition() }
        // Follow the default mic when it changes.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.stop()
            self?.start(claps: claps, wake: wake)
        }
    }

    func stop() {
        stopRecognition()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        claps = false
        wake = false
    }

    private func startRecognition() {
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            return log("On-device speech recognition isn't available, so the wake word is off")
        }
        generation += 1
        let current = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = items("wakeWords")
        lock.lock()
        self.request = request
        lock.unlock()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let heard = result.map { containsWakePhrase($0.bestTranscription.formattedString) } ?? false
            let done = error != nil || result?.isFinal == true
            DispatchQueue.main.async { [weak self] in
                guard let self, current == generation, engine != nil else { return }
                if heard {
                    restartRecognition()
                    onWake?()
                } else if done {
                    // Recognition ends on its own after a long pause; pick up again shortly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, current == generation else { return }
                        restartRecognition()
                    }
                }
            }
        }
        // A long-running request keeps growing, so start a fresh one every minute.
        refresh = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in self?.restartRecognition() }
    }

    private func stopRecognition() {
        generation += 1
        refresh?.invalidate()
        refresh = nil
        lock.lock()
        request?.endAudio()
        request = nil
        lock.unlock()
        task?.cancel()
        task = nil
    }

    private func restartRecognition() {
        guard engine != nil, wake else { return }
        stopRecognition()
        startRecognition()
    }
}
