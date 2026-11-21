import AppKit
import Combine

/// State of the window, as Spek's SpekSpectrogram keeps it: the file, stream, channel, window
/// function and size, dynamic range and palette; the keys change them (see `key`).
@MainActor
final class Model: ObservableObject {
    static let shared = Model()

    static let minRange = -140, maxRange = 0
    static let minBits = 8, maxBits = 14
    /// Above this many frames (about 24 minutes at 44.1 kHz) a file is analysed a stretch at a time.
    // SPECTRUM_LONG / SPECTRUM_STRETCH (frames) lower them for tests.
    static let longFrames = ProcessInfo.processInfo.environment["SPECTRUM_LONG"].flatMap { Int($0) } ?? 64_000_000
    static let stretchFrames = ProcessInfo.processInfo.environment["SPECTRUM_STRETCH"].flatMap { Int($0) } ?? 16_000_000

    @Published private(set) var path: String?
    @Published private(set) var desc = ""
    @Published private(set) var duration = 0.0
    @Published private(set) var sampleRate = 0
    @Published private(set) var image: CGImage?
    @Published private(set) var busy = false

    @Published var palette: Palette { didSet { save(); repaint() } }
    @Published var window: WindowFunction { didSet { save(); restart() } }
    @Published var bits: Int { didSet { save(); restart() } }
    @Published var lower: Int { didSet { save(); repaint() } }
    @Published var upper: Int { didSet { save(); repaint() } }

    private(set) var streams = 0
    private(set) var channels = 0
    private var stream = 0
    private var channel = 0
    /// Columns of the spectrogram = its width in pixels; set by the view.
    private var columns = 0

    private var job: Job?
    private var spectrogram: Spectrogram?
    // The last file's probe and decoded samples, reused while only the view changes.
    private var cachedInfo: (path: String, stream: Int, info: AudioInfo)?
    private var cachedPCM: (path: String, stream: Int, pcm: PCM)?

    /// Timing of the last analysis, for the command-line test mode.
    var onFinished: ((Double) -> Void)?

    private init() {
        let d = UserDefaults.standard
        palette = Palette(rawValue: d.object(forKey: "palette") as? Int ?? Palette.default.rawValue) ?? .sox
        window = WindowFunction(rawValue: d.integer(forKey: "window")) ?? .hann
        let b = d.integer(forKey: "bits")
        bits = (Self.minBits...Self.maxBits).contains(b) ? b : 11
        let l = d.object(forKey: "lower") as? Int ?? -120
        let u = d.object(forKey: "upper") as? Int ?? 0
        let lo = max(Self.minRange, min(l, Self.maxRange - 1))
        lower = lo
        upper = max(lo + 1, min(u, Self.maxRange))
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(palette.rawValue, forKey: "palette")
        d.set(window.rawValue, forKey: "window")
        d.set(bits, forKey: "bits")
        d.set(lower, forKey: "lower")
        d.set(upper, forKey: "upper")
    }

    var fileName: String? { path.map { ($0 as NSString).lastPathComponent } }

    func open(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        path = url.path
        stream = 0
        channel = 0
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        restart()
    }

    func setColumns(_ n: Int) {
        guard n != columns else { return }
        columns = n
        restart()
    }

    func resetDefaults() {
        palette = .default; window = .hann; bits = 11; lower = -120; upper = 0
    }

    /// Spek's keys: c/C channel, f/F window function, l/L lower limit, p/P palette,
    /// s/S stream, u/U upper limit, w/W window size. Lowercase goes forward, uppercase back.
    func key(_ k: Character) {
        switch k {
        case "c": if channels > 0 { channel = (channel + 1) % channels; restart() }
        case "C": if channels > 0 { channel = (channel - 1 + channels) % channels; restart() }
        case "f": window = WindowFunction(rawValue: (window.rawValue + 1) % 3)!
        case "F": window = WindowFunction(rawValue: (window.rawValue + 2) % 3)!
        case "l": lower = min(lower + 1, upper - 1)
        case "L": lower = max(lower - 1, Self.minRange)
        case "p": palette = Palette(rawValue: (palette.rawValue + 1) % 3)!
        case "P": palette = Palette(rawValue: (palette.rawValue + 2) % 3)!
        case "s": if streams > 0 { stream = (stream + 1) % streams; channel = 0; restart() }
        case "S": if streams > 0 { stream = (stream - 1 + streams) % streams; channel = 0; restart() }
        case "u": upper = min(upper + 1, Self.maxRange)
        case "U": upper = max(upper - 1, lower + 1)
        case "w": bits = min(bits + 1, Self.maxBits)
        case "W": bits = max(bits - 1, Self.minBits)
        default: break
        }
    }

    // MARK: Analysis

    private func repaint() {
        guard let s = spectrogram else { return }
        let p = palette, l = lower, u = upper
        DispatchQueue.global(qos: .userInteractive).async {
            let img = Painter.image(s, palette: p, lower: l, upper: u)
            DispatchQueue.main.async { if self.spectrogram === s { self.image = img } }
        }
    }

    private func restart() {
        job?.cancel()
        job = nil
        guard let path, columns > 0 else { return }
        let job = Job()
        self.job = job
        busy = true
        let stream = self.stream, channel = self.channel, bits = self.bits, window = self.window
        let columns = self.columns
        let info0 = cachedInfo.flatMap { $0.path == path && $0.stream == stream ? $0.info : nil }
        let pcm0 = cachedPCM.flatMap { $0.path == path && $0.stream == stream && $0.pcm.plane(channel: channel) != nil ? $0.pcm : nil }
        // Keep the old picture until the first new columns arrive, unless it's another file.
        if info0 == nil { image = nil; spectrogram = nil }
        let started = Date()

        DispatchQueue.global(qos: .userInitiated).async {
            let info = info0 ?? Probe.run(path, stream: stream)
            trace("probe", started)
            if job.isCancelled { return }
            DispatchQueue.main.async {
                guard self.job === job else { return }
                self.cachedInfo = (path, stream, info)
                self.streams = info.streams
                self.channels = info.channels
                self.duration = info.error == nil ? info.duration : 0
                self.sampleRate = info.error == nil ? info.sampleRate : 0
                self.desc = Self.describe(info, stream: stream, channel: channel, nfft: 1 << bits, window: window)
                if info.error != nil { self.image = nil; self.spectrogram = nil; self.busy = false }
            }
            guard info.error == nil else { return }
            let frames = Int(info.duration * Double(info.sampleRate))
            guard frames > 0 else { return }

            let spec = Spectrogram(columns: columns, bits: bits, window: window)
            var slices = frames > info.sampleRate * 20 ? min(8, Tools.performanceCores) : 1
            // Slices decoded at once: one per performance core for anything longer than 20 s.
            // WMA doesn't seek to the exact sample: decoded in one piece, so columns line up as in Spek.
            if info.codec.hasPrefix("Windows Media") { slices = 1 }
            // SPECTRUM_SLICES=n: forces the number of slices (tests compare 1 with the default).
            if let s = ProcessInfo.processInfo.environment["SPECTRUM_SLICES"].flatMap({ Int($0) }), s > 0 { slices = s }

            /// Decodes `pcm` (unless it is already complete) and computes every column it covers.
            /// While the decoders run, columns are computed and shown every 150 ms on two cores (more
            /// would slow the decoders down); everything left is done at once at the end.
            func process(_ pcm: PCM, decode: Bool) -> Bool {
                let signal = DispatchSemaphore(value: 0)
                let finished = Atomic()
                if decode {
                    let decoder = Decoder()
                    job.decoder = decoder
                    Thread.detachNewThread {
                        decoder.decode(path: path, stream: stream, info: info, into: pcm) { signal.signal() }
                        if !decoder.cancelled { pcm.markComplete() }
                        trace("decoded", started)
                        finished.set()
                        signal.signal()
                    }
                } else {
                    finished.set()
                }
                var lastPass = Date.distantPast
                while !job.isCancelled {
                    let end = finished.value
                    if !end {
                        _ = signal.wait(timeout: .now() + .milliseconds(150))
                        if Date().timeIntervalSince(lastPass) < 0.15 { continue }
                    }
                    if job.isCancelled { return false }
                    lastPass = Date()
                    let changed = spec.compute(pcm: pcm, channel: channel, workers: end ? 0 : 2) { job.isCancelled }
                    if changed {
                        let (p, l, u) = DispatchQueue.main.sync { (self.palette, self.lower, self.upper) }
                        let img = Painter.image(spec, palette: p, lower: l, upper: u)
                        DispatchQueue.main.async {
                            guard self.job === job else { return }
                            self.spectrogram = spec
                            self.image = img
                        }
                    }
                    if end && (!changed || spec.finishedCount == columns) { break }
                }
                return !job.isCancelled
            }

            var cachePCM: PCM?
            if let pcm0 {
                guard process(pcm0, decode: false) else { return }
            } else if frames <= Self.longFrames {
                // Keep every channel when it fits in about 384 MB, otherwise just this one.
                let all = frames * info.channels <= 96_000_000
                let pcm = PCM(frames: frames, channels: info.channels, kept: all ? Array(0..<info.channels) : [channel], slices: slices)
                guard process(pcm, decode: true) else { return }
                if pcm.complete { cachePCM = pcm }
            } else {
                // Very long files (Spek streams them): decoded a stretch of columns at a time, about
                // 16 M samples each (6 minutes at 44.1 kHz), so memory stays small. Not kept.
                var c0 = 0
                while c0 < columns {
                    let lo = max(0, spec.interval(c0, frames: frames).2[0] - spec.nfft)
                    var c1 = c0 + 1
                    while c1 < columns, spec.interval(c1, frames: frames).1 - lo <= Self.stretchFrames { c1 += 1 }
                    let hi = min(frames, spec.interval(c1 - 1, frames: frames).1)
                    let pcm = PCM(frames: hi - lo, channels: info.channels, kept: [channel], slices: slices, base: lo, total: frames)
                    guard process(pcm, decode: true) else { return }
                    c0 = c1
                }
            }
            if job.isCancelled { return }
            trace("computed", started)
            let elapsed = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                guard self.job === job else { return }
                if let cachePCM { self.cachedPCM = (path, stream, cachePCM) }
                self.busy = false
                self.onFinished?(elapsed)
            }
        }
    }

    /// The line under the file name, as spek_pipeline_desc builds it.
    static func describe(_ info: AudioInfo, stream: Int, channel: Int, nfft: Int, window: WindowFunction) -> String {
        var items: [String] = []
        if !info.codec.isEmpty { items.append(info.codec) }
        if info.bitRate > 0 { items.append("\((info.bitRate + 500) / 1000) kbps") }
        if info.sampleRate > 0 { items.append("\(info.sampleRate) Hz") }
        if info.bitsPerSample > 0 && info.bitRate == 0 {
            items.append("\(info.bitsPerSample) \(info.bitsPerSample == 1 ? "bit" : "bits")")
        }
        if info.channels > 0 { items.append("channel \(channel + 1) / \(info.channels)") }
        if info.error == nil {
            items.append("W:\(nfft)")
            items.append("F:\(window.name)")
        }
        let desc = items.joined(separator: ", ")
        let error = info.error ?? ""
        if desc.isEmpty { return error }
        if stream < info.streams && info.error == nil { return "Stream \(stream + 1) / \(info.streams): \(desc)" }
        if !error.isEmpty { return "\(error): \(desc)" }
        return desc
    }
}

final class Job: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var decoder: Decoder?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; let d = decoder; lock.unlock(); d?.cancel() }
}

final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

private let tracing = ProcessInfo.processInfo.environment["SPECTRUM_TRACE"] != nil
/// SPECTRUM_TRACE=1: prints when each step of an analysis ends.
func trace(_ what: String, _ start: Date) {
    if tracing { print(String(format: "  %@ %.3f s", what, Date().timeIntervalSince(start))) }
}
