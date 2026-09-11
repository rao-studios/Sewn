import SwiftUI

/// Stable per-owner accent tints for citation highlights.
enum CitationPalette {
    private static let tints: [Color] = [
        .sewnGold,
        Color(red: 110/255, green: 140/255, blue: 180/255),
        Color(red: 140/255, green: 110/255, blue: 170/255),
        Color(red: 100/255, green: 155/255, blue: 120/255),
        Color(red: 190/255, green: 120/255, blue: 100/255),
    ]

    /// Deterministic tint per owner: index by position in the contribution's
    /// sorted owner list so colors are stable within a message.
    static func color(for ownerId: String, in contribution: ChatContribution?) -> Color {
        let owners = (contribution?.owners ?? [])
            .compactMap { $0.ownerId }
            .sorted()
        guard let index = owners.firstIndex(of: ownerId) else { return .sewnGold }
        return tints[index % tints.count]
    }
}

/// Renders response text with contribution spans highlighted per owner.
/// Spans are `[lower, upper)` character offsets into the final text — applied
/// only when the message is complete, with range guards.
///
/// When `emphasizedDocumentId` is set, only that source file's exact spans
/// (`document_spans` from the citation-marker path) are highlighted, at a
/// stronger tint — everything else renders plain.
struct CitationText: View {
    let text: String
    let contribution: ChatContribution?
    var emphasizedDocumentId: String? = nil

    var body: some View {
        Text(attributed)
            .font(.sewnSans(13.5))
            .foregroundStyle(Color.sewnInk)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        guard let owners = contribution?.owners else { return result }

        let characterCount = text.count
        for owner in owners {
            guard let ownerId = owner.ownerId else { continue }
            let tint = CitationPalette.color(for: ownerId, in: contribution)

            if let documentId = emphasizedDocumentId {
                // Per-document mode: only this file's exact spans, stronger tint.
                let spans = owner.documentSpans?[documentId] ?? []
                apply(spans, to: &result, characterCount: characterCount,
                      tint: tint, background: 0.32, underline: 0.8)
            } else {
                apply(owner.spans ?? [], to: &result, characterCount: characterCount,
                      tint: tint, background: 0.18, underline: 0.5)
            }
        }
        return result
    }

    private func apply(
        _ spans: [TextSpan],
        to result: inout AttributedString,
        characterCount: Int,
        tint: Color,
        background: Double,
        underline: Double
    ) {
        for span in spans {
            guard span.lower >= 0, span.upper > span.lower,
                  span.upper <= characterCount else { continue }
            // Map character offsets into AttributedString indices.
            guard let lower = result.characters.index(
                    result.startIndex, offsetBy: span.lower, limitedBy: result.endIndex),
                  let upper = result.characters.index(
                    result.startIndex, offsetBy: span.upper, limitedBy: result.endIndex),
                  lower < upper else { continue }
            result[lower..<upper].backgroundColor = tint.opacity(background)
            result[lower..<upper].underlineStyle = .single
            result[lower..<upper].underlineColor = NSColor(tint).withAlphaComponent(underline)
        }
    }
}
