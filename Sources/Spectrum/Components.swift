import SwiftUI

// Shared look of the suite (from Mantainance and Scene): fixed measures, text tones that turn
// grey in an inactive window, larger toolbar icons, faint cards.

enum Layout {
    static let footerHeight: CGFloat = 37
    static let gutter: CGFloat = 20
    static let top: CGFloat = 15.5
}

/// Colour of texts and symbols: the given style in the active window, one grey when inactive.
struct Tone: ViewModifier {
    @Environment(\.controlActiveState) private var state
    @Environment(\.isEnabled) private var isEnabled
    let style: AnyShapeStyle

    static let inactive = Color(nsColor: .secondaryLabelColor)
    static let disabled = Color(nsColor: .tertiaryLabelColor)

    func body(content: Content) -> some View {
        if !isEnabled { return content.foregroundStyle(AnyShapeStyle(Self.disabled)) }
        return content.foregroundStyle(state == .inactive ? AnyShapeStyle(Self.inactive) : style)
    }
}

extension View {
    func tone<S: ShapeStyle>(_ style: S) -> some View { modifier(Tone(style: AnyShapeStyle(style))) }

    /// Toolbar icons a little larger than the default.
    func toolbarIcon() -> some View {
        self.font(.system(size: 17, weight: .regular)).imageScale(.large).modifier(ToolbarDim())
    }
}

/// Toolbar icons: lit when usable, light grey when not.
struct ToolbarDim: ViewModifier {
    @Environment(\.controlActiveState) private var state
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View {
        let color: Color = !isEnabled ? Tone.disabled : (state == .inactive ? Tone.inactive : Color(nsColor: .labelColor))
        return content.foregroundStyle(color)
    }
}

/// Faint panel grouping one subject, with a title row.
struct Card<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) { header }
            // Thin line between the title row and the list.
            Divider()
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}
