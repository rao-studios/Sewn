import Foundation
import PDFKit

/// Extracts plain text from the document formats the Library can ingest.
/// Raw bytes are never sent to a Thread: RTF markup or PDF binary would pollute
/// the corpus and the extracted graph entities (e.g. "ansicpg1252" concepts).
enum DocumentText {

    /// File extensions the Library's picker offers.
    static let supportedExtensions = ["txt", "md", "text", "rtf", "rtfd", "html", "htm", "pdf"]

    /// Returns the document's plain text, or nil when the file is unreadable
    /// or contains no extractable text (e.g. a scanned image-only PDF).
    static func extract(from url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url) else { return nil }
            let pages = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
            let text = pages.joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text

        case "rtf", "rtfd", "html", "htm":
            // NSAttributedString handles rich-text containers; .string is the
            // visible text with all markup stripped.
            guard let attributed = try? NSAttributedString(
                url: url, options: [:], documentAttributes: nil) else { return nil }
            let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text

        default:
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
