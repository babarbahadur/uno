import SwiftUI
import AppKit

// MARK: - Palette (taken from the Uno logo: warm porcelain white with taupe accents)

extension Color {
    /// A colour that switches between light and dark appearance.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: CGFloat(isDark ? darkAlpha : lightAlpha))
        })
    }
}

enum Theme {
    /// Window background: the "clay" everything is pressed out of.
    static let background = Color(light: 0xEDEAE4, dark: 0x252320)
    /// Raised surfaces (cards, panels, tiles).
    static let surface = Color(light: 0xF4F2ED, dark: 0x2C2A27)
    /// Neumorphic light source (top-left) and shade (bottom-right).
    static let shadowLight = Color(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.9, darkAlpha: 0.05)
    static let shadowDark = Color(light: 0xBDB4A8, dark: 0x000000, lightAlpha: 0.65, darkAlpha: 0.55)

    static let ink = Color(light: 0x48433D, dark: 0xECE6DE)
    static let inkSoft = Color(light: 0x8B847B, dark: 0xA39B91)

    /// Taupe from the logo's ring and dot.
    static let accent = Color(light: 0xA69D92, dark: 0xBDB3A7)
    static let accentDeep = Color(light: 0x7F766C, dark: 0xD3C9BD)
    static let accentTop = Color(light: 0xB3AAA0, dark: 0x91887E)
    static let accentBottom = Color(light: 0x8D847A, dark: 0x6E665D)

    static let success = Color(light: 0x7F9A86, dark: 0x9DB8A3)
    static let danger = Color(light: 0xB0533F, dark: 0xE08A76)

    static let accentGradient = LinearGradient(colors: [accentTop, accentBottom], startPoint: .top, endPoint: .bottom)
}

// MARK: - Neumorphic surfaces

struct NeuRaised: ViewModifier {
    var radius: CGFloat = 20
    var depth: CGFloat = 8
    var fill: Color = Theme.surface

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill)
                .shadow(color: Theme.shadowDark, radius: depth, x: depth * 0.6, y: depth * 0.6)
                .shadow(color: Theme.shadowLight, radius: depth, x: -depth * 0.6, y: -depth * 0.6)
        )
    }
}

struct NeuInset: ViewModifier {
    var radius: CGFloat = 14
    var depth: CGFloat = 4

    func body(content: Content) -> some View {
        content.background(
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.background)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.shadowDark, lineWidth: depth)
                    .blur(radius: depth)
                    .offset(x: depth / 2, y: depth / 2)
                    .mask(RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: [.black, .clear], startPoint: .topLeading, endPoint: .bottomTrailing)))
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.shadowLight, lineWidth: depth)
                    .blur(radius: depth)
                    .offset(x: -depth / 2, y: -depth / 2)
                    .mask(RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: [.clear, .black], startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        )
    }
}

extension View {
    /// A soft surface that appears to rise out of the background.
    func neuRaised(radius: CGFloat = 20, depth: CGFloat = 8) -> some View {
        modifier(NeuRaised(radius: radius, depth: depth))
    }

    /// A soft well pressed into the background.
    func neuInset(radius: CGFloat = 14, depth: CGFloat = 4) -> some View {
        modifier(NeuInset(radius: radius, depth: depth))
    }
}

private struct NeuPressable: ViewModifier {
    let pressed: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        if pressed {
            content.neuInset(radius: radius, depth: 3)
        } else {
            content.neuRaised(radius: radius, depth: 4)
        }
    }
}

// MARK: - Buttons

/// Soft, raised button that presses in when clicked.
struct NeuButtonStyle: ButtonStyle {
    var radius: CGFloat = 11

    func makeBody(configuration: Configuration) -> some View {
        NeuButtonBody(configuration: configuration, radius: radius)
    }

    private struct NeuButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let radius: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.callout.weight(.medium))
                .foregroundStyle(configuration.role == .destructive ? Theme.danger : Theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .modifier(NeuPressable(pressed: configuration.isPressed, radius: radius))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

/// Main call-to-action: a taupe pill from the logo.
struct NeuProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NeuProminentBody(configuration: configuration)
    }

    private struct NeuProminentBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(Theme.accentGradient)
                        .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
                        .shadow(color: Theme.shadowDark, radius: configuration.isPressed ? 2 : 7,
                                x: configuration.isPressed ? 1 : 4, y: configuration.isPressed ? 1 : 4)
                        .shadow(color: Theme.shadowLight, radius: 6, x: -3, y: -3)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .contentShape(Capsule())
        }
    }
}

/// Slight press feedback for large tiles.
struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == NeuButtonStyle {
    static var neu: NeuButtonStyle { NeuButtonStyle() }
}

extension ButtonStyle where Self == NeuProminentButtonStyle {
    static var neuProminent: NeuProminentButtonStyle { NeuProminentButtonStyle() }
}

// MARK: - Small components

/// Inset track with a taupe fill.
struct NeuProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color.clear.neuInset(radius: 6, depth: 2)
                Capsule(style: .continuous)
                    .fill(Theme.accentGradient)
                    .frame(width: max(10, (geo.size.width - 4) * min(max(value, 0), 1)))
                    .padding(2)
                    .animation(.easeOut(duration: 0.2), value: value)
            }
        }
        .frame(height: 12)
    }
}

/// Tool symbol on a small raised porcelain tile.
struct ToolIcon: View {
    let tool: ToolID
    var size: CGFloat = 46

    var body: some View {
        Image(systemName: tool.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tool.tint)
            .frame(width: size, height: size)
            .neuRaised(radius: size * 0.32, depth: max(2, size / 12))
    }
}

/// Search field pressed into the surface.
struct NeuSearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.inkSoft)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.ink)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.inkSoft)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .neuInset(radius: 12, depth: 3)
    }
}
