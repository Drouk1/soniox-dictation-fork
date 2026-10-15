import Accelerate
import AppKit
import AVFoundation
import ServiceManagement

let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
let model = "stt-rt-v5"
let sampleRate = 16_000.0
let hotKeyCode: UInt16 = 61  // right Option
let minHold = 0.25

let defaults = UserDefaults.standard

func languageHints() -> [String] {
    if let custom = defaults.stringArray(forKey: "languages"), !custom.isEmpty { return custom }
    let system = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
    return Array(NSOrderedSet(array: system + ["en"])) as! [String]
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

final class Recorder {
    private let engine = AVAudioEngine()
    var onChunk: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?

    func start() throws {
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
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
        if let terms = defaults.stringArray(forKey: "terms"), !terms.isEmpty { config["context"] = ["terms": terms] }
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
    private var pressedAt = Date.distantPast
    private var apiKey = Keychain.read()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if !defaults.bool(forKey: "didRegisterLogin") {
            try? SMAppService.mainApp.register()
            defaults.set(true, forKey: "didRegisterLogin")
        }
        if apiKey == nil { askForKey() }

        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.flagsChanged($0) }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.flagsChanged($0); return $0 }
        recorder.onLevel = { [weak self] level in DispatchQueue.main.async { self?.overlay.level = level } }
    }

    private func flagsChanged(_ event: NSEvent) {
        guard event.keyCode == hotKeyCode else { return }
        event.modifierFlags.contains(.option) ? begin() : end()
    }

    private func begin() {
        guard transcription == nil else { return }
        guard let apiKey else { return fail("No Soniox API key set") }
        let current = Transcription(apiKey: apiKey)
        recorder.onChunk = { current.send($0) }
        do {
            try recorder.start()
        } catch {
            current.cancel()
            return fail(error.localizedDescription)
        }
        transcription = current
        pressedAt = Date()
        overlay.show(.listening)
        setIcon(recording: true)
    }

    private func end() {
        guard let current = transcription else { return }
        recorder.stop()
        transcription = nil
        setIcon(recording: false)
        guard Date().timeIntervalSince(pressedAt) >= minHold else {
            current.cancel()
            return overlay.hide()
        }
        overlay.mode = .working
        current.finish { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                overlay.hide()
                if !text.isEmpty { paste(text, submit: defaults.bool(forKey: "autoEnter")) }
            case .failure(let error):
                fail(error.localizedDescription)
            }
        }
    }

    private func fail(_ message: String) {
        NSLog("Dictation: %@", message)
        overlay.show(.error)
        overlay.hide(after: 0.8)
        NSSound(named: "Basso")?.play()
        statusItem.button?.toolTip = "Last error: \(message)"
    }

    private func setIcon(recording: Bool) {
        statusItem.button?.image = NSImage(systemSymbolName: recording ? "waveform.circle.fill" : "waveform",
                                           accessibilityDescription: "Dictation")
    }

    private func buildMenu() {
        setIcon(recording: false)
        let menu = NSMenu()
        menu.delegate = self
        let hint = NSMenuItem(title: "Hold right ⌥ and speak", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(item("Press Enter after pasting", #selector(toggleAutoEnter)))
        menu.addItem(item("Launch at login", #selector(toggleLogin)))
        menu.addItem(item("Set Soniox API key…", #selector(askForKey)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTitle: "Press Enter after pasting")?.state = defaults.bool(forKey: "autoEnter") ? .on : .off
        menu.item(withTitle: "Launch at login")?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleAutoEnter() { defaults.set(!defaults.bool(forKey: "autoEnter"), forKey: "autoEnter") }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        try? service.status == .enabled ? service.unregister() : service.register()
    }

    @objc private func askForKey() {
        let alert = NSAlert()
        alert.messageText = "Soniox API key"
        alert.informativeText = "Get one at console.soniox.com. It is stored in your macOS Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Keychain.write(key)
        apiKey = key
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
