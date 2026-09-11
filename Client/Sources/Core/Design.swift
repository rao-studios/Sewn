import SwiftUI

// MARK: - Palette (warm editorial "Sewn" language — light-only)

extension Color {
    static let sewnBG     = Color(red: 250/255, green: 249/255, blue: 246/255)
    static let sewnInk    = Color(red:  45/255, green:  49/255, blue:  66/255)
    static let sewnGold   = Color(red: 174/255, green: 144/255, blue:  96/255)
    static var sewnBorder: Color { Color.sewnGold.opacity(0.22) }
    static var sewnCard:   Color { Color.white.opacity(0.62) }
    static var sewnFill:   Color { Color.sewnInk.opacity(0.05) }
    static let sewnError  = Color(red: 200/255, green:  60/255, blue:  60/255)
    static let sewnGreen  = Color(red:  90/255, green: 150/255, blue:  95/255)
    static let sewnLabel  = Color(red:  12/255, green:  12/255, blue:  12/255)
}

// MARK: - Layout metrics

/// Shared layout constants — every screen/pane header, footer, and control
/// derives from these so bars line up across panes and buttons match heights.
enum SewnMetrics {
    /// Height of the serif-22 screen title bars (Workspace/Servers/Lab).
    static let screenHeaderHeight: CGFloat = 52
    /// Fixed pane-header height (fits two compact control rows; single-row
    /// headers center vertically) — keeps all pane dividers on one line.
    static let paneHeaderHeight: CGFloat = 84
    /// Slim status/trace footers at the bottom of panes.
    static let footerBarHeight: CGFloat = 40
    /// Minimum height for SewnButtonStyle buttons.
    static let controlHeight: CGFloat = 28
    /// Square icon-button side.
    static let iconButton: CGFloat = 26
}

// MARK: - Typography

extension Font {
    static func sewnSerif(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        let f = Font.system(size: size, weight: weight, design: .serif)
        return italic ? f.italic() : f
    }

    static func sewnSans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func sewnMono(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }
}

// MARK: - Brand mark

/// The Sewn glyph — an eye in gold, hierarchical rendering.
struct SewnMark: View {
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: "eye.circle")
            .font(.system(size: size, weight: .light))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color.sewnGold)
    }
}

// MARK: - Orbiting rings + emblem (landing / empty states)

struct SewnOrbitRings: View {
    let iconSize: CGFloat
    @State private var outerRotation = 0.0
    @State private var innerRotation = 0.0

    var body: some View {
        ZStack {
            // Outer dashed ring
            Circle()
                .strokeBorder(
                    Color.sewnGold.opacity(0.30),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 3])
                )
                .frame(width: iconSize + 40, height: iconSize + 40)
                .rotationEffect(.degrees(outerRotation))
                .onAppear {
                    withAnimation(.linear(duration: 32).repeatForever(autoreverses: false)) {
                        outerRotation = -360
                    }
                }

            // Inner solid ring
            Circle()
                .strokeBorder(Color.sewnGold.opacity(0.30), lineWidth: 1)
                .frame(width: iconSize + 14, height: iconSize + 14)
                .rotationEffect(.degrees(innerRotation))
                .onAppear {
                    withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                        innerRotation = 360
                    }
                }

            // Radial glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.sewnGold.opacity(0.18), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: iconSize
                    )
                )
                .frame(width: iconSize + 40, height: iconSize + 40)
        }
    }
}

struct SewnEmblem: View {
    var iconSize: CGFloat = 56
    var body: some View {
        ZStack {
            SewnOrbitRings(iconSize: iconSize)
            SewnMark(size: iconSize * 0.6)
        }
        .frame(width: iconSize + 48, height: iconSize + 48)
    }
}
