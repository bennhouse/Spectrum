import AppKit
import SwiftUI

/// The spectrogram and everything around it, laid out like Spek's SpekSpectrogram::render: file
/// name and properties above, time ruler below, frequency ruler on the left, the palette with the
/// dB ruler on the right and the app name in the top right corner. Same measures; drawn with the
/// system fonts and colours so it follows light and dark mode.
final class SpectrogramNSView: NSView {
    static let LPAD: CGFloat = 60, TPAD: CGFloat = 60, RPAD: CGFloat = 90, BPAD: CGFloat = 40
    static let GAP: CGFloat = 10, RULER: CGFloat = 10

    var path: String? { didSet { needsDisplay = true } }
    var desc = "" { didSet { needsDisplay = true } }
    var duration = 0.0 { didSet { needsDisplay = true } }
    var sampleRate = 0 { didSet { needsDisplay = true } }
    var image: CGImage? { didSet { needsDisplay = true } }
    var palette = Palette.default { didSet { paletteImage = nil; needsDisplay = true } }
    var lower = -120 { didSet { needsDisplay = true } }
    var upper = 0 { didSet { needsDisplay = true } }
    var busy = false { didSet { needsDisplay = true } }
    var onColumns: ((Int) -> Void)?
    var onDrop: ((URL) -> Void)?
    var onKey: ((Character) -> Void)?

    private var paletteImage: CGImage?
    private var dropHighlight = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        reportColumns()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportColumns()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportColumns()
    }

    private var pendingColumns: DispatchWorkItem?
    /// One column per pixel of the spectrogram's width (Spek: one per point); reported a moment
    /// after a resize ends, so dragging the window doesn't restart the analysis at every step.
    private func reportColumns() {
        let scale = window?.backingScaleFactor ?? 2
        let n = max(0, Int(((bounds.width - Self.LPAD - Self.RPAD) * scale).rounded()))
        pendingColumns?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onColumns?(n) }
        pendingColumns = item
        let live = inLiveResize
        DispatchQueue.main.asyncAfter(deadline: .now() + (live ? 0.15 : 0), execute: item)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        reportColumns()
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let ch = event.characters?.first, "cCfFlLpPsSuUwW".contains(ch) else {
            super.keyDown(with: event); return
        }
        onKey?(ch)
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    // MARK: Drop (one file, as Spek)

    private func droppedURL(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let urls, urls.count == 1 else { return nil }
        return urls[0]
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard droppedURL(sender) != nil else { return [] }
        dropHighlight = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false
        guard let url = droppedURL(sender) else { return false }
        onDrop?(url)
        return true
    }

    // MARK: Drawing

    private var fonts: (normal: NSFont, large: NSFont, small: NSFont) {
        (.systemFont(ofSize: 12), .systemFont(ofSize: 13, weight: .semibold),
         .monospacedDigitSystemFont(ofSize: 10, weight: .regular))
    }

    override func draw(_ dirtyRect: NSRect) {
        render(in: bounds)
    }

    /// Draws the whole view; also used to save the PNG.
    func render(in b: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = b.width, h = b.height
        let LPAD = Self.LPAD, TPAD = Self.TPAD, RPAD = Self.RPAD, BPAD = Self.BPAD, GAP = Self.GAP, RULER = Self.RULER
        let f = fonts
        let primary = NSColor.labelColor, secondary = NSColor.secondaryLabelColor
        func height(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender) }
        let normalH = height(f.normal), largeH = height(f.large), smallH = height(f.small)
        let area = CGRect(x: LPAD, y: TPAD, width: w - LPAD - RPAD, height: h - TPAD - BPAD)
        let radius: CGFloat = 6

        // App name and version, top right.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: f.large, .foregroundColor: primary]
        let name = "Spectrum" as NSString
        let nameY = TPAD - 2 * GAP - normalH - largeH
        let nameW = ("Spectrum " as NSString).size(withAttributes: nameAttrs).width
        let versionAttrs: [NSAttributedString.Key: Any] = [.font: f.small, .foregroundColor: secondary]
        let blockW = nameW + (version as NSString).size(withAttributes: versionAttrs).width
        // Where Spek puts it, moved left when it would run past the window's edge.
        let nameX = min(w - RPAD + GAP, w - GAP - blockW)
        name.draw(at: CGPoint(x: nameX, y: nameY), withAttributes: nameAttrs)
        (version as NSString).draw(at: CGPoint(x: nameX + nameW, y: nameY + largeH - smallH - 1), withAttributes: versionAttrs)

        guard area.width > 0, area.height > 0 else { return }

        // The spectrogram, in a rounded frame like the suite's panels.
        let frame = CGPath(roundedRect: area, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.addPath(frame); ctx.clip()
        // Background: the palette's lowest colour (silence), so an empty area reads as the plot.
        let low = palette.color(0)
        ctx.setFillColor(CGColor(srgbRed: CGFloat((low >> 16) & 0xFF) / 255, green: CGFloat((low >> 8) & 0xFF) / 255,
                                 blue: CGFloat(low & 0xFF) / 255, alpha: 1))
        ctx.fill(area)
        if let image, path != nil {
            ctx.interpolationQuality = .high
            // CGContext draws images bottom-up; flip for this flipped view.
            ctx.translateBy(x: 0, y: area.maxY + area.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: area)
        }
        ctx.restoreGState()
        if path == nil || image == nil {
            let hint = path == nil ? "Drop an audio file here, or press ⌘O" : (busy ? "" : desc)
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: f.normal, .foregroundColor: NSColor.white.withAlphaComponent(0.55), .paragraphStyle: para]
            let s = hint as NSString
            let sz = s.boundingRect(with: CGSize(width: area.width - 20, height: area.height), options: [.usesLineFragmentOrigin], attributes: attrs)
            s.draw(with: CGRect(x: area.minX + 10, y: area.midY - sz.height / 2, width: area.width - 20, height: sz.height),
                   options: [.usesLineFragmentOrigin], attributes: attrs)
        }
        // Hairline border.
        ctx.addPath(CGPath(roundedRect: area.insetBy(dx: 0.25, dy: 0.25), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setStrokeColor((dropHighlight ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor)
        ctx.setLineWidth(dropHighlight ? 2 : 0.5)
        ctx.strokePath()

        if let path {
            // File name and properties.
            let nameStr = trim(path, font: f.large, width: min(area.width, nameX - GAP - LPAD), end: false)
            nameStr.draw(at: CGPoint(x: LPAD, y: TPAD - 2 * GAP - normalH - largeH), withAttributes: [.font: f.large, .foregroundColor: primary])
            let descStr = trim(desc, font: f.normal, width: area.width, end: true)
            descStr.draw(at: CGPoint(x: LPAD, y: TPAD - GAP - normalH), withAttributes: [.font: f.normal, .foregroundColor: secondary])
        }

        let rulerAttrs: [NSAttributedString.Key: Any] = [.font: f.small, .foregroundColor: secondary]
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        ctx.setLineWidth(1)
        if path != nil, image != nil, duration > 0 {
            Ruler(x: LPAD, y: h - BPAD, pos: .bottom, sample: "00:00", factors: [1, 2, 5, 10, 20, 30, 60, 120, 300, 600, 1200, 1800],
                  min: 0, max: Int(duration), spacing: 1.5, scale: area.width / duration, offset: 0,
                  format: { String(format: "%d:%02d", $0 / 60, $0 % 60) }).draw(ctx, rulerAttrs)
        }
        if path != nil, image != nil, sampleRate > 0 {
            let freq = sampleRate / 2
            Ruler(x: LPAD, y: TPAD, pos: .left, sample: "00 kHz", factors: [1000, 2000, 5000, 10000, 20000],
                  min: 0, max: freq, spacing: 3, scale: area.height / CGFloat(freq), offset: 0,
                  format: { "\($0 / 1000) kHz" }).draw(ctx, rulerAttrs)
        }

        // The palette and the dB ruler.
        let bar = CGRect(x: w - RPAD + GAP, y: TPAD, width: RULER, height: area.height)
        if paletteImage == nil { paletteImage = makePaletteImage() }
        if let paletteImage {
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.clip()
            ctx.translateBy(x: 0, y: bar.maxY + bar.minY); ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(paletteImage, in: bar)
            ctx.restoreGState()
            ctx.addPath(CGPath(roundedRect: bar.insetBy(dx: 0.25, dy: 0.25), cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.setStrokeColor(NSColor.separatorColor.cgColor); ctx.setLineWidth(0.5); ctx.strokePath()
        }
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        ctx.setLineWidth(1)
        Ruler(x: bar.maxX, y: TPAD, pos: .right, sample: "-00 dB", factors: [1, 2, 5, 10, 20, 50],
              min: -upper, max: -lower, spacing: 3, scale: area.height / CGFloat(lower - upper), offset: area.height,
              format: { "\(-$0) dB" }).draw(ctx, rulerAttrs)
    }

    private func makePaletteImage() -> CGImage? {
        let n = 512
        var px = palette.table(n).reversed().map { $0 }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let data = px.withUnsafeMutableBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: 1, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Spek's trim(): shortens `s` with "..." so it fits in `width`, keeping the start or the end.
    private func trim(_ s: String, font: NSFont, width: CGFloat, end: Bool) -> NSString {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        func wd(_ t: String) -> CGFloat { (t as NSString).size(withAttributes: attrs).width }
        if width <= 0 { return "" }
        if wd(s) <= width { return s as NSString }
        let chars = Array(s)
        var i = 0, k = chars.count
        while k - i > 1 {
            let j = (i + k) / 2
            let t = end ? String(chars[..<j]) + "…" : "…" + String(chars[j...])
            if end != (wd(t) > width) { i = j } else { k = j }
        }
        return (end ? String(chars[..<i]) + "…" : "…" + String(chars[k...])) as NSString
    }
}

/// Spek's SpekRuler: picks the first factor that leaves enough room between labels and draws
/// the ticks with their labels.
struct Ruler {
    enum Position { case top, right, bottom, left }
    let x: CGFloat, y: CGFloat, pos: Position, sample: String, factors: [Int]
    let min: Int, max: Int, spacing: CGFloat, scale: CGFloat, offset: CGFloat
    let format: (Int) -> String

    func draw(_ ctx: CGContext, _ attrs: [NSAttributedString.Key: Any]) {
        let size = (sample as NSString).size(withAttributes: attrs)
        let len = pos == .top || pos == .bottom ? size.width : size.height
        var factor = 0
        for f in factors where abs(scale * CGFloat(f)) >= spacing * len { factor = f; break }
        tick(ctx, attrs, min)
        tick(ctx, attrs, max)
        if factor > 0 {
            var t = min + factor
            while t < max {
                if abs(scale * CGFloat(max - t)) < len * 1.2 { break }
                tick(ctx, attrs, t)
                t += factor
            }
        }
    }

    private func tick(_ ctx: CGContext, _ attrs: [NSAttributedString.Key: Any], _ t: Int) {
        let GAP: CGFloat = 10, LEN: CGFloat = 4
        let label = format(t) as NSString
        let value = pos == .top || pos == .bottom ? t : max + min - t
        let p = offset + scale * CGFloat(value - min)
        let s = label.size(withAttributes: attrs)
        switch pos {
        case .top: label.draw(at: CGPoint(x: x + p - s.width / 2, y: y - GAP - s.height), withAttributes: attrs)
        case .right: label.draw(at: CGPoint(x: x + GAP, y: y + p - s.height / 2), withAttributes: attrs)
        case .bottom: label.draw(at: CGPoint(x: x + p - s.width / 2, y: y + GAP - 2), withAttributes: attrs)
        case .left: label.draw(at: CGPoint(x: x - s.width - GAP, y: y + p - s.height / 2), withAttributes: attrs)
        }
        ctx.beginPath()
        switch pos {
        case .top: ctx.move(to: CGPoint(x: x + p, y: y)); ctx.addLine(to: CGPoint(x: x + p, y: y - LEN))
        case .right: ctx.move(to: CGPoint(x: x, y: y + p)); ctx.addLine(to: CGPoint(x: x + LEN, y: y + p))
        case .bottom: ctx.move(to: CGPoint(x: x + p, y: y)); ctx.addLine(to: CGPoint(x: x + p, y: y + LEN))
        case .left: ctx.move(to: CGPoint(x: x, y: y + p)); ctx.addLine(to: CGPoint(x: x - LEN, y: y + p))
        }
        ctx.strokePath()
    }
}

struct SpectrogramView: NSViewRepresentable {
    @ObservedObject var model: Model

    func makeNSView(context: Context) -> SpectrogramNSView {
        let v = SpectrogramNSView()
        v.onColumns = { n in Task { @MainActor in model.setColumns(n) } }
        v.onDrop = { url in Task { @MainActor in model.open(url) } }
        v.onKey = { k in Task { @MainActor in model.key(k) } }
        MainView.current = v
        return v
    }

    func updateNSView(_ v: SpectrogramNSView, context: Context) {
        v.path = model.path
        v.desc = model.desc
        v.duration = model.duration
        v.sampleRate = model.sampleRate
        v.image = model.image
        v.palette = model.palette
        v.lower = model.lower
        v.upper = model.upper
        v.busy = model.busy
    }
}

@MainActor
enum MainView {
    static weak var current: SpectrogramNSView?
}
