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

/// Drops everything up to and including the wake phrase: "OK, hey Claude, write…" → "Write…".
/// Returns the text unchanged if the phrase isn't in it.
func stripWakePhrase(_ text: String) -> String {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    // Positions in the folded copy only carry over if folding didn't change the length.
    guard folded.utf16.count == text.utf16.count else { return text }
    for phrase in items("wakeWords") {
        var words = normalized(phrase).split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard let last = words.last else { continue }
        // Soniox sometimes hears the name a little differently ("hey clawed"), so only its start must match.
        if last.count > 3 { words[words.count - 1] = String(last.prefix(3)) + "\\p{L}*" }
        let pattern = "^.*?(?<![\\p{L}\\p{N}])" + words.joined(separator: "[^\\p{L}\\p{N}]+") + "(?![\\p{L}\\p{N}])[^\\p{L}\\p{N}]*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: folded, range: NSRange(location: 0, length: folded.utf16.count)) else { continue }
        let rest = (text as NSString).substring(from: match.range.upperBound)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }
    return text
}

/// Watches idle mic audio for a double clap and/or the wake phrase.
/// The wake phrase is recognised on this Mac; no audio leaves it until dictation starts.
final class IdleListener {
    var onClap: (() -> Void)?
    var onWake: (() -> Void)?
    private var claps = false
    private var wake = false

    private let lock = NSLock()
    private var detector: ClapDetector?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var refresh: Timer?

    func configure(claps: Bool, wake: Bool) {
        if claps != self.claps {
            lock.lock()
            detector = claps ? ClapDetector() : nil
            lock.unlock()
            self.claps = claps
        }
        if wake != self.wake {
            self.wake = wake
            wake ? startRecognition() : stopRecognition()
        }
    }

    /// Called on the audio thread with every mic buffer.
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if detector != nil, let samples = buffer.floatChannelData?[0],
           detector!.feed(samples, count: Int(buffer.frameLength), rate: buffer.format.sampleRate) {
            DispatchQueue.main.async { [weak self] in
                guard let self, claps else { return }
                onClap?()
            }
        }
        request?.append(buffer)
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
                guard let self, current == generation, wake else { return }
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
        guard wake else { return }
        stopRecognition()
        startRecognition()
    }
}
