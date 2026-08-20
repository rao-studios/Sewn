import AppKit
import SwiftUI

/// A floating card surface in the warm design language. Fills its container's
/// width by construction — cards stacked in a column are always equal width,
/// never sized to their content (constrain the column, not the card).
struct SeerCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.seerCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(Color.seerBorder, lineWidth: 1))
            )
            .shadow(color: Color.seerInk.opacity(0.06), radius: 5, y: 2)
    }
}

/// Small uppercase section label. Single-line by construction — labels in
/// compressible rows truncate rather than wrap or push siblings out.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.seerSans(10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color.seerInk.opacity(0.45))
            .lineLimit(1)
    }
}

/// Gold primary-action button style. Fixed minimum height so every button in
/// a row (Start/Logs, Search/Ingest, Query/Trace…) lands at the same size.
struct SeerButtonStyle: ButtonStyle {
    var prominent: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.seerSans(12.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: SeerMetrics.controlHeight)
            .foregroundStyle(prominent ? Color.white : Color.seerInk)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(prominent ? Color.seerGold : Color.seerFill)
                    .opacity(configuration.isPressed ? 0.8 : 1)
            )
            .shadow(
                color: prominent ? Color.seerGold.opacity(0.30) : .clear,
                radius: 4, y: 2)
    }
}

extension ButtonStyle where Self == SeerButtonStyle {
    static var seer: SeerButtonStyle { SeerButtonStyle(prominent: true) }
    static var seerQuiet: SeerButtonStyle { SeerButtonStyle(prominent: false) }
}

/// Uniform square icon button (refresh, close, remove…) — one size everywhere.
struct SeerIconButtonStyle: ButtonStyle {
    var tint: Color = Color.seerInk.opacity(0.65)
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: SeerMetrics.iconButton, height: SeerMetrics.iconButton)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.seerFill)
                    .opacity(configuration.isPressed ? 0.6 : 1)
            )
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == SeerIconButtonStyle {
    static var seerIcon: SeerIconButtonStyle { SeerIconButtonStyle() }
    static func seerIcon(tint: Color) -> SeerIconButtonStyle { SeerIconButtonStyle(tint: tint) }
}

// MARK: - Shared bars

/// Screen-level title bar: serif title (+ optional leading accessory) and
/// trailing controls at a fixed height, with built-in clearance for the hidden
/// titlebar's traffic-light band.
struct ScreenHeader<Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(title: String,
         @ViewBuilder leading: () -> Leading = { EmptyView() },
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.seerSerif(22, weight: .light, italic: true))
                .foregroundStyle(Color.seerInk)
                .fixedSize()
            leading
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 24)
        .frame(height: SeerMetrics.screenHeaderHeight)
    }
}

/// Pane-level control header at a fixed height regardless of row count, so the
/// dividers of side-by-side panes always form one continuous line. Content
/// rows inherit the compact control size.
struct PaneHeader<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SeerMetrics.paneHeaderHeight)
    }
}

/// Slim pane footer (trace bar, status bar) at a fixed height on `seerFill`.
struct PaneFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SeerMetrics.footerBarHeight)
        .background(Color.seerFill)
    }
}

/// Colored status dot.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

/// Small capsule tag (kind chips, status pills). Single-line and
/// middle-truncating by construction so long values (model names, ids) can
/// never wrap or force a row past its bounds — cap width at the call site
/// with `.frame(maxWidth:)` when the content is unbounded.
struct SeerPill: View {
    let text: String
    var tint: Color = .seerGold
    var body: some View {
        Text(text)
            .font(.seerMono(10))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.14)))
            .foregroundStyle(Color.seerInk.opacity(0.75))
    }
}

/// Empty-state hero with the Seer emblem.
struct EmptyHero: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 16) {
            SeerEmblem(iconSize: 56)
            Text(title)
                .font(.seerSerif(20, weight: .light, italic: true))
                .foregroundStyle(Color.seerInk)
            Text(subtitle)
                .font(.seerSans(12))
                .foregroundStyle(Color.seerInk.opacity(0.45))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Open a file picker and return the chosen files.
enum FilePicker {
    static func pickFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func pickDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        return panel.runModal() == .OK ? panel.urls.first : nil
    }
}
