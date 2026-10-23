import Accelerate
import AVFoundation

/// Finds a double clap in a stream of mic samples: two sharp bangs 0.15–0.8 s apart,
/// with no other bang just before or after, so typing and speech don't set it off.
struct ClapDetector {
    private var floor: Float = 0.001
    private var previous: Float = 0
    private var beforePrevious: Float = 0
    private var time = 0.0
    private var pending: (at: Double, peak: Float)?
    private var onsets: [Double] = []
    private var claps: [Double] = []

    /// Returns true when the samples complete a double clap.
    mutating func feed(_ samples: UnsafePointer<Float>, count: Int, rate: Double) -> Bool {
        let window = max(Int(rate / 100), 1)  // 10 ms
        var start = 0
        var fired = false
        while start + window <= count {
            var rms: Float = 0
            vDSP_rmsqv(samples + start, 1, &rms, vDSP_Length(window))
            fired = step(rms) || fired
            time += Double(window) / rate
            start += window
        }
        time += Double(count - start) / rate
        return fired
    }

    private mutating func step(_ rms: Float) -> Bool {
        defer { (beforePrevious, previous) = (previous, rms) }
        // Compare with the quieter of the last two windows, in case a bang starts right at a window's end.
        let onset = rms > max(0.012, floor * 4) && rms > min(previous, beforePrevious) * 3
        if let p = pending {
            let age = time - p.at
            if age < 0.03 {
                pending!.peak = max(p.peak, rms)
                return false
            }
            // Another bang before this one has died away means it wasn't a lone clap.
            if onset || age >= 0.12 {
                pending = nil
                // A clap dies away within ~100 ms; a voice or music keeps going.
                if !onset, rms < p.peak * 0.2 { claps.append(p.at) }
            }
        }
        if onset {
            pending = (time, rms)
            onsets.append(time)
        } else if pending == nil {
            floor = max(floor * 0.99 + rms * 0.01, 0.0005)
        }
        onsets.removeAll { time - $0 > 2 }
        claps.removeAll { time - $0 > 1.5 }

        // Wait a moment after the second clap to make sure a third isn't coming.
        guard claps.count >= 2, let b = claps.last, time - b >= 0.4, pending == nil else { return false }
        let a = claps[claps.count - 2]
        let nearby = onsets.filter { $0 > a - 0.5 && $0 <= time }.count
        claps.removeAll()
        guard (0.15...0.8).contains(b - a), nearby == 2 else { return false }
        onsets.removeAll()
        return true
    }
}

/// Keeps the mic open while idle and calls onDoubleClap when it hears one.
final class ClapListener {
    var onDoubleClap: (() -> Void)?
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?

    func start() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        var detector = ClapDetector()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let samples = buffer.floatChannelData?[0] else { return }
            if detector.feed(samples, count: Int(buffer.frameLength), rate: format.sampleRate) {
                DispatchQueue.main.async { self?.onDoubleClap?() }
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return NSLog("Dictation: clap listener failed: %@", error.localizedDescription)
        }
        self.engine = engine
        // Follow the default mic when it changes.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.stop()
            self?.start()
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
