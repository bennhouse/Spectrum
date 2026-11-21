import Foundation

/// Spek's palettes (spek-palette.cc), same formulas. Values are packed 0xRRGGBB.
enum Palette: Int, CaseIterable {
    case spectrum, sox, mono

    static let `default` = Palette.sox

    var name: String { ["Spectrum", "SoX", "Mono"][rawValue] }

    func color(_ level: Double) -> UInt32 {
        switch self {
        case .spectrum: return Self.spectrum(level)
        case .sox: return Self.sox(level)
        case .mono: return Self.mono(level)
        }
    }

    func table(_ n: Int) -> [UInt32] { (0..<n).map { color(Double($0) / Double(n - 1)) } }

    // Modified version of Dan Bruton's algorithm.
    private static func spectrum(_ l: Double) -> UInt32 {
        let level = l * 0.6625
        var r = 0.0, g = 0.0, b = 0.0
        if level >= 0 && level < 0.15 {
            r = (0.15 - level) / (0.15 + 0.075); g = 0; b = 1
        } else if level >= 0.15 && level < 0.275 {
            r = 0; g = (level - 0.15) / (0.275 - 0.15); b = 1
        } else if level >= 0.275 && level < 0.325 {
            r = 0; g = 1; b = (0.325 - level) / (0.325 - 0.275)
        } else if level >= 0.325 && level < 0.5 {
            r = (level - 0.325) / (0.5 - 0.325); g = 1; b = 0
        } else if level >= 0.5 && level < 0.6625 {
            r = 1; g = (0.6625 - level) / (0.6625 - 0.5); b = 0
        }
        var cf = 1.0
        if level >= 0 && level < 0.1 { cf = level / 0.1 }
        cf *= 255
        return pack(r * cf, g * cf, b * cf)
    }

    // The default palette used by SoX, written by Rob Sykes.
    private static func sox(_ level: Double) -> UInt32 {
        var r = 0.0
        if level >= 0.13 && level < 0.73 { r = sin((level - 0.13) / 0.60 * .pi / 2) } else if level >= 0.73 { r = 1 }
        var g = 0.0
        if level >= 0.6 && level < 0.91 { g = sin((level - 0.6) / 0.31 * .pi / 2) } else if level >= 0.91 { g = 1 }
        var b = 0.0
        if level < 0.60 { b = 0.5 * sin(level / 0.6 * .pi) } else if level >= 0.78 { b = (level - 0.78) / 0.22 }
        return pack(r * 255, g * 255, b * 255)
    }

    private static func mono(_ level: Double) -> UInt32 {
        let v = level * 255
        return pack(v, v, v)
    }

    private static func pack(_ r: Double, _ g: Double, _ b: Double) -> UInt32 {
        func c(_ x: Double) -> UInt32 { UInt32(max(0, min(255, x + 0.5))) }
        return 0xFF00_0000 | (c(r) << 16) | (c(g) << 8) | c(b)
    }
}
