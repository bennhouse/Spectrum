import AppKit
import SwiftUI

/// Spek's keybindings (its manual), shown with F1 instead of opening a web page.
struct HelpView: View {
    private let menu: [(String, String)] = [
        ("⌘O", "Open a new file."),
        ("⌘S", "Save the spectrogram as an image file."),
        ("⌘,", "Show the settings."),
        ("F1", "Show this help."),
        ("⇧F1", "Show the about window."),
    ]
    private let spectrogram: [(String, String)] = [
        ("c  C", "Change the audio channel."),
        ("f  F", "Change the DFT window function."),
        ("l  L", "Change the lower limit of the dynamic range in dBFS."),
        ("p  P", "Change the palette."),
        ("s  S", "Change the audio stream."),
        ("u  U", "Change the upper limit of the dynamic range in dBFS."),
        ("w  W", "Change the DFT window size."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Spectrum generates a spectrogram for the input audio file. Drop a file on the window or the Dock icon, or open one with ⌘O.")
                .fixedSize(horizontal: false, vertical: true)
                .tone(.secondary)
            Card { Text("Menu").font(.headline) } content: { table(menu) }
            Card { Text("Spectrogram").font(.headline) } content: {
                table(spectrogram)
                Text("Lowercase goes forward, uppercase (with ⇧) goes back. The same commands are in the Spectrogram menu.")
                    .font(.caption).tone(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Layout.gutter)
        .frame(width: 460)
    }

    private func table(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { r in
                GridRow {
                    Text(r.0).font(.system(.body, design: .monospaced)).frame(width: 46, alignment: .leading)
                    Text(r.1).tone(.primary)
                }
            }
        }
    }
}

/// Spek's Preferences held the language and the update check; here macOS sets the language and
/// nothing goes online, so Settings holds what the keys change, remembered between launches.
struct SettingsView: View {
    @ObservedObject private var model = Model.shared

    var body: some View {
        Form {
            Picker("Palette:", selection: $model.palette) {
                ForEach(Palette.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            Picker("Window function:", selection: $model.window) {
                ForEach(WindowFunction.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            Picker("Window size:", selection: $model.bits) {
                ForEach(Model.minBits...Model.maxBits, id: \.self) { Text("\(1 << $0)").tag($0) }
            }
            LabeledContent("Dynamic range:") {
                HStack(spacing: 6) {
                    Stepper(value: $model.lower, in: Model.minRange...(model.upper - 1)) {
                        Text("\(model.lower) dB").monospacedDigit().frame(width: 58, alignment: .trailing)
                    }
                    Text("to").tone(.secondary)
                    Stepper(value: $model.upper, in: (model.lower + 1)...Model.maxRange) {
                        Text("\(model.upper) dB").monospacedDigit().frame(width: 58, alignment: .trailing)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Restore Defaults") { model.resetDefaults() }
            }
            .padding(.top, 6)
        }
        .padding(Layout.gutter)
        .frame(width: 400)
    }
}

/// Command-line test mode, no window:
///   Spectrum --render FILE OUT.png [WIDTH HEIGHT]
/// analyses FILE at the given window size (points, 2× pixels), prints the timings, writes the PNG.
@MainActor
enum CLI {
    static func render(_ args: [String]) {
        guard args.count >= 2 else { print("usage: Spectrum --render FILE OUT.png [WIDTH HEIGHT]"); exit(2) }
        let w = args.count > 2 ? Double(args[2]) ?? 640 : 640, h = args.count > 3 ? Double(args[3]) ?? 452 : 452
        _ = NSApplication.shared
        let t0 = Date()
        let view = SpectrogramNSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        let model = Model.shared
        view.onColumns = { _ in }
        model.onFinished = { elapsed in
            print(String(format: "analysis %.3f s", elapsed))
            view.path = model.path; view.desc = model.desc; view.duration = model.duration
            view.sampleRate = model.sampleRate; view.image = model.image; view.palette = model.palette
            view.lower = model.lower; view.upper = model.upper
            Actions.write(view: view, to: URL(fileURLWithPath: args[1]))
            print(model.desc)
            print(String(format: "total %.3f s", Date().timeIntervalSince(t0)))
            exit(0)
        }
        model.open(URL(fileURLWithPath: args[0]))
        model.setColumns(Int((w - SpectrogramNSView.LPAD - SpectrogramNSView.RPAD) * 2))
        RunLoop.main.run()
    }
}
