import AppKit

/// Development aid: with SPECTRUM_SNAPSHOT=<folder> in the environment, Spectrum writes a PNG of each of
/// its windows (toolbar included) every second, so the layout can be checked without screen
/// recording permission. Does nothing otherwise.
@MainActor
enum Snapshots {
    private static var timer: Timer?

    static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SPECTRUM_SNAPSHOT"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                // Which window has the focus (to check that nothing steals it).
                let key = NSApp.keyWindow.map { $0.title.isEmpty ? "main window" : $0.title } ?? "none"
                try? (key + "\n").write(toFile: "\(dir)/key.txt", atomically: true, encoding: .utf8)
                for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                    guard let frameView = w.contentView?.superview else { continue }
                    let b = frameView.bounds
                    guard let rep = frameView.bitmapImageRepForCachingDisplay(in: b) else { continue }
                    frameView.cacheDisplay(in: b, to: rep)
                    let name = w.title.isEmpty ? "window\(i)" : w.title.replacingOccurrences(of: " ", with: "-")
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                    // The window as the window server composites it (materials, vibrancy), which
                    // cacheDisplay doesn't draw. An app may capture its own windows without permission.
                    if let img = WindowCapture.image(w.windowNumber) {
                        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: "\(dir)/\(name)-screen.png"))
                    }
                }
            }
        }
    }
}

/// CGWindowListCreateImage, looked up at run time: the macOS 15 SDK marks it unavailable, but it
/// still works for an app's own windows, which is all the snapshots need.
enum WindowCapture {
    private typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let fn: Fn? = {
        guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func image(_ windowNumber: Int, nominal: Bool = false) -> CGImage? {
        // includingWindow = 1 << 3; boundsIgnoreFraming = 1, bestResolution = 1 << 3, nominal = 1 << 4
        fn?(.null, 1 << 3, UInt32(windowNumber), 1 | (nominal ? 1 << 4 : 1 << 3))?.takeRetainedValue()
    }
}
