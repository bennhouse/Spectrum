import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SpectrumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = Model.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Spectrum", id: "main") {
            ContentView()
        }
        .defaultSize(width: 640, height: 480)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { Actions.open() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save…") { Actions.save() }.keyboardShortcut("s").disabled(model.path == nil)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Spectrum") { Actions.about() }.keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF1FunctionKey)!)), modifiers: .shift)
            }
            CommandGroup(replacing: .help) {
                Button("Spectrum Help") { openWindow(id: "help") }.keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF1FunctionKey)!)), modifiers: [])
            }
            CommandMenu("Spectrogram") {
                Section {
                    Button("Next Channel") { model.key("c") }.keyboardShortcut("c", modifiers: [])
                    Button("Previous Channel") { model.key("C") }.keyboardShortcut("c", modifiers: .shift)
                    Button("Next Stream") { model.key("s") }.keyboardShortcut("s", modifiers: [])
                    Button("Previous Stream") { model.key("S") }.keyboardShortcut("s", modifiers: .shift)
                }
                Section {
                    Picker("Window Function", selection: $model.window) {
                        ForEach(WindowFunction.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    Button("Next Window Function") { model.key("f") }.keyboardShortcut("f", modifiers: [])
                    Button("Previous Window Function") { model.key("F") }.keyboardShortcut("f", modifiers: .shift)
                    Button("Larger Window") { model.key("w") }.keyboardShortcut("w", modifiers: [])
                    Button("Smaller Window") { model.key("W") }.keyboardShortcut("w", modifiers: .shift)
                }
                Section {
                    Button("Raise Upper Limit") { model.key("u") }.keyboardShortcut("u", modifiers: [])
                    Button("Lower Upper Limit") { model.key("U") }.keyboardShortcut("u", modifiers: .shift)
                    Button("Raise Lower Limit") { model.key("l") }.keyboardShortcut("l", modifiers: [])
                    Button("Lower Lower Limit") { model.key("L") }.keyboardShortcut("l", modifiers: .shift)
                }
                Section {
                    Picker("Palette", selection: $model.palette) {
                        ForEach(Palette.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    Button("Next Palette") { model.key("p") }.keyboardShortcut("p", modifiers: [])
                    Button("Previous Palette") { model.key("P") }.keyboardShortcut("p", modifiers: .shift)
                }
            }
        }

        Window("Spectrum Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .scrollIndicators(.never)
        }
    }
}

struct ContentView: View {
    @ObservedObject private var model = Model.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SpectrogramView(model: model)
            .frame(minWidth: 400, minHeight: 300)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(model.fileName ?? "Spectrum")
            .modifier(DocumentProxy(path: model.path))
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { Actions.open() } label: { Image(systemName: "folder").toolbarIcon() }
                        .help("Open…")
                    Button { Actions.save() } label: { Image(systemName: "square.and.arrow.down").toolbarIcon() }
                        .help("Save…")
                        .disabled(model.path == nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { openWindow(id: "help") } label: { Image(systemName: "questionmark.circle").toolbarIcon() }
                        .help("Help")
                }
            }
    }
}

@MainActor
enum Actions {
    // Spek's open dialog: audio files by default, any file allowed.
    static let audioExtensions = ["3gp", "aac", "aif", "aifc", "aiff", "amr", "awb", "ape", "au", "dts", "flac", "flv", "gsm",
                                  "m4a", "m4p", "mp3", "mp4", "mp+", "mpc", "mpp", "oga", "ogg", "opus", "ra", "ram", "snd",
                                  "wav", "wma", "wv"]

    static func open() {
        let panel = NSOpenPanel()
        panel.title = "Open File"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Model.shared.open(url)
    }

    static func save() {
        guard let view = MainView.current, let path = Model.shared.path else { return }
        let panel = NSSavePanel()
        panel.title = "Save Spectrogram"
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (path as NSString).lastPathComponent + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(view: view, to: url)
    }

    static func write(view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        // Opaque background so the PNG reads the same outside the app.
        view.cacheDisplay(in: view.bounds, to: rep)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let img = rep.cgImage else { return }
        var bg = NSColor.windowBackgroundColor.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { bg = NSColor.windowBackgroundColor.cgColor }
        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return }
        let png = NSBitmapImageRep(cgImage: out)
        png.size = view.bounds.size
        try? png.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func about() {
        let credits = NSMutableAttributedString(string:
            "A native macOS version of Spek, the acoustic spectrum analyser.\n\n" +
            "Spek © 2010–2023 Alexander Kojevnikov and contributors: Andreas Cadhalpun, Colin Watson, Daniel Hams, " +
            "Elias Ojala, Fabian Deutsch, Guillaume Fourrier, Jakov Smolic, Jonathan Gonzalez V, Matteo Bini, Mike Wang, " +
            "Simon Ruderich, Stefan Kost, Thibault North, Wyatt J. Brown. Artwork by Olga Vasylevska.\n\n" +
            "Licensed under the GNU GPL v3. Decoding by FFmpeg.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Snapshots.startIfRequested()
            // `Spectrum FILE` opens it, as `spek FILE`.
            let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            if let p = args.first, FileManager.default.fileExists(atPath: p) { Model.shared.open(URL(fileURLWithPath: p)) }
            if let p = ProcessInfo.processInfo.environment["SPECTRUM_OPEN"] { Model.shared.open(URL(fileURLWithPath: p)) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { if let u = urls.first { Model.shared.open(u) } }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--render" {
    MainActor.assumeIsolated { CLI.render(Array(CommandLine.arguments.dropFirst(2))) }
} else {
    SpectrumApp.main()
}

/// The file's proxy icon in the title bar, only when a file is open.
struct DocumentProxy: ViewModifier {
    let path: String?
    func body(content: Content) -> some View {
        if let path { content.navigationDocument(URL(fileURLWithPath: path)) } else { content }
    }
}
