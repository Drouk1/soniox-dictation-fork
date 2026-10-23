import AVFoundation
import Speech

/// Lowercased, accent-free, letters and digits only, single spaces: "Hey, Claude!" → "hey claude".
func normalized(_ text: String) -> String {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    return folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
        .split(separator: " ").joined(separator: " ")
}

/// A rough sound-alike spelling, so a Greek name matches what the English recognizer writes:
/// "έλα μπίτζο" and "Ella Beetso" both become "elabiso".
func soundKey(_ text: String) -> String {
    var t = " " + normalized(text.applyingTransform(.toLatin, reverse: false) ?? text) + " "
    for (from, to) in [(" mp", " b"), (" nt", " d"), (" gk", " g"), ("ph", "f"), ("ck", "k"), ("c", "k"), ("q", "k"),
                       ("x", "ks"), ("tz", "s"), ("ts", "s"), ("dz", "s"), ("z", "s"), ("j", "s"),
                       ("ee", "i"), ("ea", "i"), ("ie", "i"), ("y", "i"), ("oo", "u"), ("ou", "u"), ("w", "u"), ("h", "")] {
        t = t.replacingOccurrences(of: from, with: to)
    }
    var key = ""
    for c in t where c != " " && c != key.last { key.append(c) }
    return key
}

func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    var row = Array(0...b.count)
    for i in 1...max(a.count, 1) where !a.isEmpty {
        var previous = row[0]
        row[0] = i
        for j in 1...max(b.count, 1) where !b.isEmpty {
            let current = row[j]
            row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
            previous = current
        }
    }
    return a.isEmpty ? b.count : row[b.count]
}

func containsWakePhrase(_ text: String) -> Bool {
    let heard = " \(normalized(text)) "
    let words = normalized(text.applyingTransform(.toLatin, reverse: false) ?? text).split(separator: " ")
    return items("wakeWords").contains { phrase in
        let exact = normalized(phrase)
        guard !exact.isEmpty else { return false }
        if heard.contains(" \(exact) ") { return true }
        // Otherwise compare by sound, over runs of about as many words as the phrase has.
        let key = soundKey(phrase)
        let count = exact.split(separator: " ").count
        let allowed = max(1, key.count / 4)
        for n in max(1, count - 1)...(count + 1) where n <= words.count {
            for start in 0...(words.count - n) where editDistance(soundKey(words[start..<start + n].joined(separator: " ")), key) <= allowed {
                return true
            }
        }
        return false
    }
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
        request.contextualStrings = items("wakeWords").map { normalized($0.applyingTransform(.toLatin, reverse: false) ?? $0) }
        lock.lock()
        self.request = request
        lock.unlock()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let heard = result.map { containsWakePhrase($0.bestTranscription.formattedString) } ?? false
            // For tuning names: `defaults write io.github.harabalos.dictation debugWake -bool true` logs what was heard.
            if let result, defaults.bool(forKey: "debugWake") { log("Wake heard: \(result.bestTranscription.formattedString)") }
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
