import Accelerate
import Foundation

// The analysis, ported from Spek's spek-audio / spek-pipeline / spek-fft:
//  - the file is read with ffprobe (streams, codec, bitrate, duration) and decoded with ffmpeg;
//  - the duration is split into as many intervals as the spectrogram has columns; each column is
//    the average, in dB, of the FFTs that end every `nfft` samples inside its interval (one FFT
//    at the end of the interval when it is shorter than that), exactly as Spek's worker does.
// What is new is the speed: the file is decoded by several ffmpeg processes at once, each one a
// slice of the duration, columns are computed as soon as their samples are in, and the decoded
// samples stay in memory, so changing the window size or function, the channel or the window
// width recomputes from memory instead of decoding the file again.

enum WindowFunction: Int, CaseIterable {
    case hann, hamming, blackmanHarris
    var name: String { ["Hann", "Hamming", "Blackman–Harris"][rawValue] }
}

struct AudioInfo {
    var streams = 0
    var codec = ""
    var bitRate = 0
    var sampleRate = 0
    var bitsPerSample = 0
    var channels = 0
    var duration = 0.0
    var error: String?
}

enum Tools {
    static var bin: URL {
        if let dir = ProcessInfo.processInfo.environment["SPECTRUM_TOOLS"] { return URL(fileURLWithPath: dir) }
        return Bundle.main.resourceURL!.appendingPathComponent("bin")
    }
    static var ffmpeg: URL { bin.appendingPathComponent("ffmpeg") }
    static var ffprobe: URL { bin.appendingPathComponent("ffprobe") }

    static var performanceCores: Int {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &n, &size, nil, 0) == 0, n > 0 { return Int(n) }
        return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }
}

enum Probe {
    /// Reads the audio stream `stream` (0-based among the audio streams) like Spek's Audio::open.
    static func run(_ path: String, stream: Int) -> AudioInfo {
        var info = AudioInfo()
        let p = Process()
        p.executableURL = Tools.ffprobe
        p.arguments = ["-v", "error", "-of", "json", "-show_format", "-show_streams", "-select_streams", "a", path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { info.error = "Cannot open input file"; return info }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            info.error = "Cannot open input file"; return info
        }
        let streams = json["streams"] as? [[String: Any]] ?? []
        let format = json["format"] as? [String: Any] ?? [:]
        if streams.isEmpty && format.isEmpty { info.error = "Cannot open input file"; return info }
        info.streams = streams.count
        guard stream < streams.count else { info.error = "The file contains no audio streams"; return info }
        let s = streams[stream]
        func int(_ v: Any?) -> Int { (v as? String).flatMap { Int($0) } ?? (v as? Int) ?? 0 }
        func dbl(_ v: Any?) -> Double? { (v as? String).flatMap { Double($0) } ?? (v as? Double) }
        let codecName = s["codec_name"] as? String ?? ""
        info.codec = (s["codec_long_name"] as? String) ?? codecName
        info.bitRate = int(s["bit_rate"])
        info.sampleRate = int(s["sample_rate"])
        info.bitsPerSample = int(s["bits_per_raw_sample"])
        if info.bitsPerSample == 0 { info.bitsPerSample = int(s["bits_per_sample"]) }
        // These decoders set both bps and bitrate (Spek).
        if ["aac", "musepack8", "wmav1", "wmav2"].contains(codecName) { info.bitsPerSample = 0 }
        if info.bitsPerSample != 0 { info.bitRate = 0 }
        info.channels = int(s["channels"])
        if let d = dbl(s["duration"]) { info.duration = d }
        else if let d = dbl(format["duration"]) { info.duration = d }
        else { info.error = "Unknown duration" }
        if info.error == nil, info.channels <= 0 { info.error = "No audio channels" }
        if info.error == nil, codecName.isEmpty || codecName == "none" { info.error = "Cannot find decoder" }
        if info.error == nil, info.sampleRate <= 0 { info.error = "Unsupported sample format" }
        return info
    }
}

/// Decoded samples of one stream: one plane per channel kept in memory. For very long files a
/// PCM holds only a stretch of the stream: frames [base, base + frames) of `total`.
final class PCM: @unchecked Sendable {
    let frames: Int
    let base: Int
    let total: Int
    let channels: Int
    /// Channels that are decoded and stored (all of them when the file is small enough).
    let kept: [Int]
    private(set) var planes: [UnsafeMutablePointer<Float>]
    /// Slices decoded in parallel: start frame of each, and how many frames each has filled.
    let starts: [Int]
    private var filled: [Int]
    private let lock = NSLock()
    var complete = false

    init(frames: Int, channels: Int, kept: [Int], slices: Int, base: Int = 0, total: Int? = nil) {
        self.frames = frames
        self.base = base
        self.total = total ?? frames
        self.channels = channels
        self.kept = kept
        planes = kept.map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            p.initialize(repeating: 0, count: frames)
            return p
        }
        starts = (0..<slices).map { Int(Int64($0) * Int64(frames) / Int64(slices)) }
        filled = Array(repeating: 0, count: slices)
    }

    deinit { planes.forEach { $0.deallocate() } }

    func plane(channel: Int) -> UnsafeMutablePointer<Float>? {
        kept.firstIndex(of: channel).map { planes[$0] }
    }

    func end(of slice: Int) -> Int { slice + 1 < starts.count ? starts[slice + 1] : frames }

    func setFilled(_ slice: Int, _ n: Int) { lock.lock(); filled[slice] = n; lock.unlock() }
    func markComplete() { lock.lock(); complete = true; lock.unlock() }

    /// True when every sample in [lo, hi) (frames of the whole stream) has been decoded.
    func available(_ lo: Int, _ hi: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Before the start and past the end is silence; outside this stretch is not here.
        var lo = max(0, lo), hi = min(total, hi)
        if lo >= hi { return true }
        if lo < base || hi > base + frames { return false }
        if complete { return true }
        lo -= base; hi -= base
        for k in starts.indices {
            let s = starts[k], e = end(of: k)
            if e <= lo || s >= hi { continue }
            if s + filled[k] < min(hi, e) { return false }
        }
        return true
    }
}

/// Decodes a stream with ffmpeg, several slices at once.
final class Decoder: @unchecked Sendable {
    private var processes: [Process] = []
    private let lock = NSLock()
    private(set) var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; let ps = processes; lock.unlock()
        ps.forEach { if $0.isRunning { $0.terminate() } }
    }

    /// Fills `pcm`, calling `progress` (from background threads) as samples arrive.
    func decode(path: String, stream: Int, info: AudioInfo, into pcm: PCM, progress: @escaping @Sendable () -> Void) {
        let group = DispatchGroup()
        let rate = Double(info.sampleRate)
        for slice in pcm.starts.indices {
            group.enter()
            Thread.detachNewThread { [self] in
                defer { group.leave() }
                let start = pcm.starts[slice], end = pcm.end(of: slice)
                var args = ["-nostdin", "-v", "error", "-threads", "1"]
                if pcm.base + start > 0 { args += ["-ss", String(format: "%.6f", Double(pcm.base + start) / rate)] }
                args += ["-i", path, "-map", "0:a:\(stream)", "-vn", "-sn", "-dn"]
                // Each slice stops a little past its end; the last one reads to the end of the file.
                if slice + 1 < pcm.starts.count || pcm.base + pcm.frames < pcm.total { args += ["-t", String(format: "%.6f", Double(end - start) / rate + 0.05)] }
                args += ["-ar", "\(info.sampleRate)", "-c:a", "pcm_f32le", "-f", "f32le", "pipe:1"]
                let p = Process()
                p.executableURL = Tools.ffmpeg
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                lock.lock()
                if cancelled { lock.unlock(); return }
                processes.append(p)
                lock.unlock()
                do { try p.run() } catch { return }
                let fd = out.fileHandleForReading.fileDescriptor
                let ch = pcm.channels
                let frameBytes = 4 * ch
                let chunk = 1 << 18
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk * frameBytes, alignment: 16)
                defer { buffer.deallocate() }
                var pending = 0          // bytes in buffer not yet consumed
                var written = 0          // frames stored for this slice
                let capacity = end - start
                var lastReport = 0
                while written < capacity {
                    let n = read(fd, buffer + pending, chunk * frameBytes - pending)
                    if n <= 0 { break }
                    pending += n
                    let frames = min(pending / frameBytes, capacity - written)
                    if frames > 0 {
                        let src = buffer.assumingMemoryBound(to: Float.self)
                        for (i, c) in pcm.kept.enumerated() {
                            let dst = pcm.planes[i] + start + written
                            if ch == 1 {
                                (dst).update(from: src, count: frames)
                            } else {
                                // Deinterleave channel c with a stride.
                                cblas_scopy(Int32(frames), src + c, Int32(ch), dst, 1)
                            }
                        }
                        written += frames
                        let used = frames * frameBytes
                        if pending > used { memmove(buffer, buffer + used, pending - used) }
                        pending -= used
                    }
                    if written - lastReport >= 1 << 16 || written >= capacity {
                        lastReport = written
                        pcm.setFilled(slice, written)
                        progress()
                    }
                    if self.cancelled { break }
                }
                // Done with this slice: the rest stays silent (shorter than the stated duration).
                pcm.setFilled(slice, capacity)
                if p.isRunning { p.terminate() }
                p.waitUntilExit()
                progress()
            }
        }
        group.wait()
    }
}

/// Spectrogram columns: `columns × bands` values in dB, computed from a PCM plane.
final class Spectrogram: @unchecked Sendable {
    let columns: Int
    let bits: Int
    let bands: Int
    let nfft: Int
    let window: WindowFunction
    let values: UnsafeMutablePointer<Float>
    private(set) var done: [Bool]
    private let lock = NSLock()

    init(columns: Int, bits: Int, window: WindowFunction) {
        self.columns = columns
        self.bits = bits
        nfft = 1 << bits
        bands = (1 << (bits - 1)) + 1
        self.window = window
        values = .allocate(capacity: columns * bands)
        values.initialize(repeating: -200, count: columns * bands)
        done = Array(repeating: false, count: columns)
    }

    deinit { values.deallocate() }

    var finishedCount: Int { lock.lock(); defer { lock.unlock() }; return done.lazy.filter { $0 }.count }
    func isDone(_ c: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return done[c] }

    /// Frames [a, b) of column `c` and where its FFTs end, as in Spek's worker.
    func interval(_ c: Int, frames: Int) -> (Int, Int, [Int]) {
        let a = Int(Int64(c) * Int64(frames) / Int64(columns))
        let b = Int(Int64(c + 1) * Int64(frames) / Int64(columns))
        var ends: [Int] = []
        var p = a + nfft
        while p <= b { ends.append(p); p += nfft }
        if ends.isEmpty { ends = [b] }
        return (a, b, ends)
    }

    /// Computes every column not done yet whose samples are available.
    func compute(pcm: PCM, channel: Int, workers maxWorkers: Int = 0, cancelled: () -> Bool) -> Bool {
        guard let plane = pcm.plane(channel: channel) else { return false }
        let frames = pcm.total, base = pcm.base
        var todo: [Int] = []
        lock.lock()
        let doneNow = done
        lock.unlock()
        for c in 0..<columns where !doneNow[c] {
            let (_, b, ends) = interval(c, frames: frames)
            if pcm.available(ends[0] - nfft, b) { todo.append(c) }
        }
        if todo.isEmpty || cancelled() { return false }
        let n = nfft
        let log2n = vDSP_Length(bits)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return false }
        defer { vDSP_destroy_fftsetup(setup) }
        // Window as Spek computes it, from a cosine table over n - 1.
        var win = [Float](repeating: 0, count: n)
        let cf = 2 * Float.pi / (Float(n) - 1)
        for i in 0..<n {
            let c1 = cos(cf * Float(i)), c2 = cos(cf * Float((2 * i) % n)), c3 = cos(cf * Float((3 * i) % n))
            switch window {
            case .hann: win[i] = 0.5 * (1 - c1)
            case .hamming: win[i] = 0.53836 - 0.46164 * c1
            case .blackmanHarris: win[i] = 0.35875 - 0.48829 * c1 + 0.14128 * c2 - 0.01168 * c3
            }
        }
        let bands = self.bands
        let workers = min(todo.count, maxWorkers > 0 ? maxWorkers : ProcessInfo.processInfo.activeProcessorCount)
        let per = (todo.count + workers - 1) / workers
        let values = self.values
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            let lo = w * per, hi = min(todo.count, lo + per)
            if lo >= hi { return }
            let input = UnsafeMutablePointer<Float>.allocate(capacity: n); defer { input.deallocate() }
            let re = UnsafeMutablePointer<Float>.allocate(capacity: n / 2); defer { re.deallocate() }
            let im = UnsafeMutablePointer<Float>.allocate(capacity: n / 2); defer { im.deallocate() }
            let power = UnsafeMutablePointer<Float>.allocate(capacity: bands); defer { power.deallocate() }
            let acc = UnsafeMutablePointer<Float>.allocate(capacity: bands); defer { acc.deallocate() }
            let n2 = Float(n) * Float(n)
            win.withUnsafeBufferPointer { winp in
                for t in lo..<hi {
                    if cancelled() { return }
                    let c = todo[t]
                    let (_, _, ends) = interval(c, frames: frames)
                    acc.initialize(repeating: 0, count: bands)
                    for p in ends {
                        let s = p - n
                        // Samples before the start or past the end are silence.
                        let from = max(0, s), to = min(frames, p)
                        input.initialize(repeating: 0, count: n)
                        if to > from { input.advanced(by: from - s).update(from: plane + (from - base), count: to - from) }
                        vDSP_vmul(input, 1, winp.baseAddress!, 1, input, 1, vDSP_Length(n))
                        var split = DSPSplitComplex(realp: re, imagp: im)
                        input.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        // vDSP's real FFT is twice the plain DFT: halve it, then |X|² / n², in dB.
                        let dc = re[0] / 2, nyq = im[0] / 2
                        power[0] = dc * dc / n2
                        power[n / 2] = nyq * nyq / n2
                        for i in 1..<(n / 2) {
                            let r = re[i] / 2, m = im[i] / 2
                            power[i] = (r * r + m * m) / n2
                        }
                        for i in 0..<bands { acc[i] += 10 * log10f(power[i]) }
                    }
                    let k = Float(ends.count)
                    let row = values + c * bands
                    for i in 0..<bands { row[i] = max(-300, acc[i] / k) }
                }
            }
        }
        if cancelled() { return true }
        lock.lock()
        for c in todo { done[c] = true }
        lock.unlock()
        return true
    }
}

/// Builds the pixels of a spectrogram with a palette and a dynamic range.
enum Painter {
    static func image(_ s: Spectrogram, palette: Palette, lower: Int, upper: Int) -> CGImage? {
        let w = s.columns, h = s.bands
        guard w > 0, h > 0 else { return nil }
        let lut = palette.table(1024)
        var pixels = [UInt32](repeating: 0, count: w * h)
        let range = Float(upper - lower)
        let lo = Float(lower), up = Float(upper)
        pixels.withUnsafeMutableBufferPointer { px in
            let base = px.baseAddress!
            DispatchQueue.concurrentPerform(iterations: min(8, w)) { part in
                let per = (w + 7) / 8
                for x in (part * per)..<min(w, (part + 1) * per) {
                    let col = s.values + x * h
                    for y in 0..<h {
                        let v = min(up, max(lo, col[y]))
                        let level = (v - lo) / range
                        base[(h - 1 - y) * w + x] = lut[min(1023, Int(level * 1023 + 0.5))]
                    }
                }
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
