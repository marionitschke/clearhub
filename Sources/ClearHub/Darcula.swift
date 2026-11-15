import AppKit
import SwiftUI

/// The look of ClearHub, mirroring StudioHub's `shared/Darcula.swift`: Darcula as in WebStorm and
/// DiaryHub – always dark, neutral grey surfaces, a grey accent for controls and selections; the
/// app's orange only marks primary actions and its own symbols.
enum Darcula {
    /// Window, lists, tables.
    static let background = color(0x2B2B2B)
    /// Panels and bars.
    static let surface = color(0x313335)
    /// Controls and raised areas on a surface; also the row lines of lists.
    static let raised = color(0x3C3F41)
    static let border = color(0x4B4F52)
    static let text = color(0xC4C7CA)
    static let muted = color(0x8F9395)
    static let faint = color(0x65696C)
    static let accent = color(0x8A8E91)
    static let danger = color(0xF26B6B)
    /// Filled danger buttons and markers, with white text.
    static let dangerFill = color(0xB91C1C)
    static let warn = color(0xF59E0B)
    static let success = color(0x3FBF63)

    /// ClearHub's main color, as in its icon: primary buttons.
    static let main = color(0xE0701E)
    /// The main color lightened for symbols and text on the dark background.
    static let ink = color(0xEC8540)
    /// The selected tab or segment, with white text: the graphite accent draws selections in a light
    /// grey on which light text is hard to read (2–3.4:1); 55 % orange on the surface gives 5.9:1.
    static let selection = main.blended(withFraction: 0.45, of: surface)!

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Must run before `NSApplication.shared` exists – AppKit reads the accent color once when it starts.
    /// Without Xcode there is no asset catalog for an app accent color; the argument domain is not
    /// saved and wins over the system setting, so the app's controls turn graphite.
    static func prepare() {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleAccentColor"] = -1
        arguments["AppleAquaColorVariant"] = 6
        arguments["AppleHighlightColor"] = "0.847059 0.847059 0.862745 Graphite"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    /// Dark for every window, sheet, alert and menu, whatever the system uses.
    @MainActor
    static func applyAppearance() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

extension View {
    /// Darcula for a whole window: its background, and the palette's text colors as the primary,
    /// secondary and tertiary foreground styles.
    @ViewBuilder
    func darculaWindow() -> some View {
        let styled = foregroundStyle(Color(nsColor: Darcula.text), Color(nsColor: Darcula.muted), Color(nsColor: Darcula.faint))
        if #available(macOS 15, *) {
            styled.containerBackground(Color(nsColor: Darcula.background), for: .window)
        } else {
            styled.background(Color(nsColor: Darcula.background)).background(DarculaWindowHook())
        }
    }

    /// A primary action in ClearHub's orange with white text, like DiaryHub's primary buttons.
    func primaryAction() -> some View {
        buttonStyle(.borderedProminent)
            .tint(Color(nsColor: Darcula.main))
            .foregroundStyle(.white)
    }

    /// A segmented picker in the content whose selected segment has the selection color.
    func darculaSegments() -> some View {
        pickerStyle(.segmented).tint(Color(nsColor: Darcula.selection))
    }

    /// White text on a selected table row: the system's selection grey can't be recolored, and the
    /// palette's text colors are too dark on it.
    func darculaRowText() -> some View { modifier(DarculaRowText()) }

    /// Secondary text in a table cell; `.secondary` stays a dim grey on a selected row.
    func darculaSecondary() -> some View { modifier(DarculaSecondary()) }

    /// A small label in a status color; white on a dark backing in a selected row, where the color
    /// would be hard to read on the selection grey.
    func darculaBadge(_ color: Color) -> some View { modifier(DarculaBadge(color: color)) }
}

private struct DarculaBadge: ViewModifier {
    let color: Color
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        let selected = prominence == .increased
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(selected ? Color.black.opacity(0.22) : color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(selected ? Color.white : color)
    }
}

private struct DarculaRowText: ViewModifier {
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        if prominence == .increased { content.foregroundStyle(Color.white) } else { content }
    }
}

private struct DarculaSecondary: ViewModifier {
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        content.foregroundStyle(prominence == .increased ? Color.white.opacity(0.9) : Color(nsColor: Darcula.muted))
    }
}

/// Tabs drawn by hand: in the toolbar, a segmented picker's selected segment is glass that ignores
/// tint and bezel colors, so its graphite grey can't be given readable contrast.
struct DarculaTabs<Value: Hashable>: View {
    let tabs: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.value) { tab in
                DarculaTab(title: tab.title, isSelected: tab.value == selection) { selection = tab.value }
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
    }
}

private struct DarculaTab: View {
    let title: String
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Color(nsColor: Darcula.text))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: Color {
        if isSelected { Color(nsColor: Darcula.selection) } else if isHovered { Color(nsColor: Darcula.raised) } else { .clear }
    }
}

/// macOS 14 has no `containerBackground(_:for: .window)`: the window itself gets the background,
/// and a transparent titlebar keeps the system's darker grey away from the toolbar.
private struct DarculaWindowHook: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HookView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class HookView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.backgroundColor = Darcula.background
            window?.titlebarAppearsTransparent = true
        }
    }
}
