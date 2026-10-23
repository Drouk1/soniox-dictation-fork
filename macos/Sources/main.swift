import Accelerate
import AppKit
import AVFoundation
import ServiceManagement
import Speech

let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
let model = "stt-rt-v5"
let sampleRate = 16_000.0
let minHold = 0.25
// Hands-free mode (after a clap or the wake word) stops once the mic has been quiet for a while.
let speechLevel: Float = 0.01  // about -40 dB
let maxHandsFree = 300.0

let defaults = UserDefaults.standard
defaults.register(defaults: [
    "hotkey": 61,
    "silenceTimeout": 3.0,
    "sounds": true,
    "enterWords": "over, enter, όβερ, έντερ",
    "wakeWords": "hey claude, hey cloud, χέι κλοντ",
])

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dictation.log")

/// Appends a line to ~/Library/Logs/Dictation.log. Never logs what was said.
func log(_ message: String) {
    NSLog("Dictation: %@", message)
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: logURL)
    }
}

struct HotKey {
    let code: UInt16
    let flag: NSEvent.ModifierFlags
    let name: String
}

let hotKeys = [
    HotKey(code: 61, flag: .option, name: "Right Option ⌥"),
    HotKey(code: 62, flag: .control, name: "Right Control ⌃"),
    HotKey(code: 54, flag: .command, name: "Right Command ⌘"),
    HotKey(code: 63, flag: .function, name: "fn"),
]

/// nil when the hotkey is turned off.
var hotKey: HotKey? { hotKeys.first { $0.code == defaults.integer(forKey: "hotkey") } }

func lines(_ key: String) -> [String] {
    (defaults.string(forKey: key) ?? "").split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// A setting holding a list separated by commas or new lines.
func items(_ key: String) -> [String] {
    (defaults.string(forKey: key) ?? "").split(whereSeparator: { $0 == "," || $0.isNewline })
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// Splits off a trailing Enter word: "Send it, over." → ("Send it", true).
func splitEnterWord(_ text: String) -> (text: String, enter: Bool) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    for word in items("enterWords") {
        guard let range = trimmed.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .backwards, .anchored]) else { continue }
        let rest = trimmed[..<range.lowerBound]
        if let last = rest.last, last.isLetter || last.isNumber { continue }
        return (rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,:-–—").union(.newlines)), true)
    }
    return (text, false)
}

func play(_ sound: String) {
    if defaults.bool(forKey: "sounds") { NSSound(named: sound)?.play() }
}

func languageHints() -> [String] {
    let custom = (defaults.string(forKey: "languages") ?? "").split(whereSeparator: { ", ".contains($0) }).map(String.init)
    if !custom.isEmpty { return custom }
    let system = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
    return Array(NSOrderedSet(array: system + ["en"])) as! [String]
}

func applyReplacements(_ text: String) -> String {
    let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    return lines("replacements").reduce(text) { text, line in
        guard let arrow = ["→", "->", "="].lazy.compactMap({ line.range(of: $0) }).first else { return text }
        let heard = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let written = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !heard.isEmpty else { return text }
        // Match on a folded copy so "ΠΟΥΣΑΡΕ" and "πουσαρε" also hit "πούσαρε".
        let folded = fold(text)
        let sameLength = folded.utf16.count == text.utf16.count
        let haystack = sameLength ? folded : text
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: sameLength ? fold(heard) : heard) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        let result = NSMutableString(string: text)
        for match in regex.matches(in: haystack, range: NSRange(location: 0, length: haystack.utf16.count)).reversed() {
            result.replaceCharacters(in: match.range, with: written)
        }
        return result as String
    }
}

enum Keychain {
    static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "soniox-dictation",
        kSecAttrAccount as String: "api-key",
    ]

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String) {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// The one place the mic is opened. It runs while dictating, and also while idle when
/// claps or the wake word are on, so dictation can pick up without a gap.
final class Recorder {
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    var onChunk: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start() throws {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "Dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported microphone format"])
        }
        let ratio = sampleRate / inFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            if let samples = buffer.floatChannelData?[0] {
                var rms: Float = 0
                vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
                self.onLevel?(rms)
            }
            self.onBuffer?(buffer)
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if out.frameLength > 0, let ptr = out.int16ChannelData?[0] {
                self.onChunk?(Data(bytes: ptr, count: Int(out.frameLength) * 2))
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        // Follow the default mic when it changes.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.stop()
            do { try self?.start() } catch { log("Mic restart failed: \(error.localizedDescription)") }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}

/// Sends mic audio to the current transcription. While idle it keeps the last few seconds,
/// so "Hey Claude, write…" can be said in one go and the words after the name aren't lost.
final class AudioRouter {
    private let lock = NSLock()
    private var sink: Transcription?
    private var recent: [Data] = []
    private var recentBytes = 0
    private let keepBytes = Int(sampleRate * 4) * 2

    func route(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        if let sink { return sink.send(chunk) }
        recent.append(chunk)
        recentBytes += chunk.count
        while recentBytes - recent[0].count >= keepBytes { recentBytes -= recent.removeFirst().count }
    }

    func attach(_ transcription: Transcription, withRecent: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if withRecent { recent.forEach(transcription.send) }
        recent = []
        recentBytes = 0
        sink = transcription
    }

    func detach() {
        lock.lock()
        sink = nil
        lock.unlock()
    }
}

final class Transcription {
    private let task: URLSessionWebSocketTask
    private let queue = DispatchQueue(label: "soniox")
    private var text = ""
    private var result: Result<String, Error>?
    private var completion: ((Result<String, Error>) -> Void)?

    init(apiKey: String) {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        var config: [String: Any] = [
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": Int(sampleRate),
            "num_channels": 1,
            "language_hints": languageHints(),
            "enable_language_identification": true,
        ]
        var terms = lines("vocabulary")
        if defaults.bool(forKey: "wakeWord") { terms += items("wakeWords") }
        if !terms.isEmpty { config["context"] = ["terms": terms] }
        let json = try! JSONSerialization.data(withJSONObject: config)
        task.send(.string(String(decoding: json, as: UTF8.self))) { _ in }
        receive()
    }

    func send(_ audio: Data) { task.send(.data(audio)) { _ in } }

    func finish(_ completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            if let result = self.result { return DispatchQueue.main.async { completion(result) } }
            self.completion = completion
            self.task.send(.string("")) { _ in }
        }
        queue.asyncAfter(deadline: .now() + 15) { self.complete(.failure(Self.error("Soniox timed out"))) }
    }

    func cancel() { queue.async { self.complete(.success("")) } }

    private func receive() {
        task.receive { [weak self] message in
            guard let self else { return }
            self.queue.async { self.handle(message) }
        }
    }

    private func handle(_ message: Result<URLSessionWebSocketTask.Message, Error>) {
        guard result == nil else { return }
        let data: Data
        switch message {
        case .failure(let error): return complete(.failure(error))
        case .success(.string(let s)): data = Data(s.utf8)
        case .success(.data(let d)): data = d
        case .success: return receive()
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return receive() }
        if let code = obj["error_code"] {
            return complete(.failure(Self.error("Soniox \(code): \(obj["error_message"] ?? "")")))
        }
        for token in obj["tokens"] as? [[String: Any]] ?? [] where token["is_final"] as? Bool == true {
            if let t = token["text"] as? String, !t.hasPrefix("<") { text += t }
        }
        if obj["finished"] as? Bool == true {
            complete(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        } else {
            receive()
        }
    }

    private func complete(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        task.cancel(with: .normalClosure, reason: nil)
        if let completion { DispatchQueue.main.async { completion(result) } }
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "Dictation", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

func pressKey(_ key: CGKeyCode, _ flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}

func paste(_ text: String, submit: Bool) {
    let pb = NSPasteboard.general
    let saved = pb.pasteboardItems?.map { item -> NSPasteboardItem in
        let copy = NSPasteboardItem()
        for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
        return copy
    } ?? []
    pb.clearContents()
    pb.setString(text, forType: .string)
    pressKey(9, .maskCommand)
    if submit { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { pressKey(36) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        guard !saved.isEmpty else { return }
        pb.clearContents()
        pb.writeObjects(saved)
    }
}

final class WaveView: NSView {
    enum Mode { case listening, working, error }
    var mode = Mode.listening
    var level: Float = 0
    private var smoothed: CGFloat = 0
    private let weights: [CGFloat] = [0.55, 0.85, 1, 0.8, 0.6]

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.08, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()

        let t = CACurrentMediaTime()
        let db = 20 * log10(max(Double(level), 1e-6))
        let target = CGFloat(min(max((db + 52) / 38, 0), 1))
        smoothed += (target - smoothed) * (target > smoothed ? 0.45 : 0.15)

        let barWidth: CGFloat = 3, gap: CGFloat = 3, minH: CGFloat = 3
        let maxH = bounds.height - 10
        var x = (bounds.width - CGFloat(weights.count) * (barWidth + gap) + gap) / 2
        let color: NSColor = switch mode {
        case .listening: .white
        case .working: NSColor(white: 1, alpha: 0.55)
        case .error: .systemRed
        }
        color.setFill()

        for (i, weight) in weights.enumerated() {
            let phase = Double(i)
            let h: CGFloat = switch mode {
            case .listening: minH + (maxH - minH) * smoothed * weight * CGFloat(0.75 + 0.25 * sin(t * 9 + phase * 1.3))
            case .working: minH + maxH * 0.35 * CGFloat(0.5 + 0.5 * sin(t * 6 - phase * 0.8))
            case .error: minH + 2
            }
            let bar = NSRect(x: x, y: (bounds.height - h) / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }
}

final class Overlay {
    private let wave = WaveView(frame: NSRect(x: 0, y: 0, width: 54, height: 24))
    private let panel: NSPanel
    private var timer: Timer?
    private var generation = 0

    init() {
        panel = NSPanel(contentRect: wave.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = wave
        panel.alphaValue = 0
    }

    var mode: WaveView.Mode {
        get { wave.mode }
        set { wave.mode = newValue }
    }

    var level: Float {
        get { wave.level }
        set { wave.level = newValue }
    }

    func show(_ mode: WaveView.Mode) {
        generation += 1
        wave.mode = mode
        guard timer == nil else { return panel.animator().alphaValue = 1 }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        let origin = NSPoint(x: screen.visibleFrame.midX - wave.frame.width / 2, y: screen.visibleFrame.minY + 28)
        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 6))
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(origin)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.wave.needsDisplay = true }
    }

    func hide(after delay: Double = 0) {
        generation += 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard current == generation else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.14; panel.animator().alphaValue = 0 }) { [self] in
                guard current == generation else { return }
                panel.orderOut(nil)
                timer?.invalidate()
                timer = nil
                wave.level = 0
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let overlay = Overlay()
    private let recorder = Recorder()
    private var transcription: Transcription?
    private let settings = SettingsWindow()
    private var pressedAt = Date.distantPast
    private let idle = IdleListener()
    private let router = AudioRouter()
    private var trigger = Trigger.hotkey
    private var handsFree = false
    private var lastSpeech = Date.distantPast
    private var lastInput = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("Started, Accessibility \(AXIsProcessTrusted() ? "on" : "off")")
        buildMenu()
        AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.updateIdleListener() } }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if !defaults.bool(forKey: "didRegisterLogin") {
            try? SMAppService.mainApp.register()
            defaults.set(true, forKey: "didRegisterLogin")
        }
        if Keychain.read() == nil { settings.show() }

        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.flagsChanged($0); return $0 }
        recorder.onLevel = { [weak self] level in DispatchQueue.main.async { self?.heard(level) } }
        recorder.onChunk = { [router] in router.route($0) }
        recorder.onBuffer = { [idle] in idle.feed($0) }
        idle.onClap = { [weak self] in
            guard let self else { return }
            // Keys and trackpad clicks can sound like claps, so ignore claps heard while typing or clicking.
            guard Date().timeIntervalSince(lastInput) > 1.5 else { return }
            begin(.clap)
        }
        idle.onWake = { [weak self] in self?.begin(.wake) }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateIdleListener()
        }
        if AXIsProcessTrusted() {
            startListening()
        } else {
            // A global monitor created before access is granted never fires, so wait for access.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.startListening()
            }
        }
    }

    // Opening the app again (double-click in Finder, `open`, Spotlight) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    private func startListening() {
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.flagsChanged($0) }
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.lastInput = Date() }
        setIcon(recording: false)
    }

    private func flagsChanged(_ event: NSEvent) {
        guard let key = hotKey, event.keyCode == key.code else { return }
        event.modifierFlags.contains(key.flag) ? begin(.hotkey) : end()
    }

    enum Trigger: String { case hotkey, clap, wake }

    private func begin(_ trigger: Trigger) {
        guard transcription == nil else { return }
        guard let apiKey = Keychain.read() else { return fail("No Soniox API key set") }
        idle.configure(claps: false, wake: false)
        let current = Transcription(apiKey: apiKey)
        do {
            try recorder.start()
        } catch {
            current.cancel()
            updateIdleListener()
            return fail(error.localizedDescription)
        }
        // After the wake word, send the last few seconds too: they hold the name and whatever followed it.
        router.attach(current, withRecent: trigger == .wake)
        transcription = current
        self.trigger = trigger
        log("Listening (\(trigger.rawValue), Accessibility \(AXIsProcessTrusted() ? "on" : "off"))")
        pressedAt = Date()
        handsFree = trigger != .hotkey
        // A little extra time to start talking after the clap or wake word.
        lastSpeech = Date().addingTimeInterval(1)
        if handsFree { play("Tink") }
        overlay.show(.listening)
        setIcon(recording: true)
    }

    private func heard(_ level: Float) {
        overlay.level = level
        guard handsFree, transcription != nil else { return }
        if level > speechLevel { lastSpeech = max(lastSpeech, Date()) }
        let silence = defaults.double(forKey: "silenceTimeout")
        if Date().timeIntervalSince(lastSpeech) > silence || Date().timeIntervalSince(pressedAt) > maxHandsFree {
            play("Pop")
            end()
        }
    }

    private func updateIdleListener() {
        guard transcription == nil else { return idle.configure(claps: false, wake: false) }
        var wake = defaults.bool(forKey: "wakeWord") && !items("wakeWords").isEmpty
        if wake {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: break
            case .notDetermined:
                SFSpeechRecognizer.requestAuthorization { _ in DispatchQueue.main.async { self.updateIdleListener() } }
                wake = false
            default: wake = false
            }
        }
        let claps = defaults.bool(forKey: "clapToStart")
        idle.configure(claps: claps, wake: wake)
        // Keep the mic open while idle only when something is listening for a clap or the name.
        if claps || wake {
            do { try recorder.start() } catch { log("Mic failed: \(error.localizedDescription)") }
        } else {
            recorder.stop()
        }
    }

    private func end() {
        guard let current = transcription else { return }
        router.detach()
        transcription = nil
        let trigger = trigger
        handsFree = false
        updateIdleListener()
        setIcon(recording: false)
        guard Date().timeIntervalSince(pressedAt) >= minHold else {
            current.cancel()
            return overlay.hide()
        }
        overlay.mode = .working
        log("Stopped after \(String(format: "%.1f", Date().timeIntervalSince(pressedAt))) s")
        current.finish { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                overlay.hide()
                let (spoken, enter) = splitEnterWord(trigger == .wake ? stripWakePhrase(text) : text)
                let text = applyReplacements(spoken)
                let submit = enter || defaults.bool(forKey: "autoEnter")
                log("Transcribed \(text.count) characters\(enter ? " + Enter word" : "")")
                guard !text.isEmpty else {
                    // Saying just "over" presses Enter.
                    if enter, AXIsProcessTrusted() { pressKey(36) }
                    return
                }
                // Without Accessibility access the paste keystroke is silently dropped, so keep the text.
                guard AXIsProcessTrusted() else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    openAccessibility()
                    return fail("Allow Accessibility access to paste. The text is on the clipboard, press ⌘V.")
                }
                paste(text, submit: submit)
            case .failure(let error):
                fail(error.localizedDescription)
            }
        }
    }

    private func fail(_ message: String) {
        log("Error: \(message)")
        overlay.show(.error)
        overlay.hide(after: 0.8)
        play("Basso")
        statusItem.button?.toolTip = "Last error: \(message)"
    }

    private func setIcon(recording: Bool) {
        let symbol = recording ? "waveform.circle.fill" : AXIsProcessTrusted() ? "waveform" : "exclamationmark.triangle"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Dictation")
    }

    private func buildMenu() {
        setIcon(recording: false)
        let menu = NSMenu()
        menu.delegate = self
        let status = NSMenuItem(title: "", action: #selector(openAccessibility), keyEquivalent: "")
        status.target = self
        menu.addItem(status)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let trusted = AXIsProcessTrusted()
        var ways: [String] = []
        if let key = hotKey { ways.append("hold \(key.name)") }
        if defaults.bool(forKey: "clapToStart") { ways.append("clap twice") }
        if defaults.bool(forKey: "wakeWord"), let phrase = items("wakeWords").first { ways.append("say “\(phrase)”") }
        let start = ways.isEmpty ? "No way to start is turned on" : ways.joined(separator: ", ").capitalizingFirstLetter + " to dictate"
        menu.items.first?.title = trusted ? start : "⚠️ Allow Accessibility access…"
        menu.items.first?.isEnabled = !trusted
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openSettings() { settings.show() }
}

extension String {
    var capitalizingFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// Text fields get ⌘C/⌘V/⌘X/⌘A/⌘Z from the main menu, which a menu bar app has none of.
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
let editItem = NSMenuItem()
editItem.submenu = editMenu
app.mainMenu = NSMenu()
app.mainMenu?.addItem(editItem)
app.run()
