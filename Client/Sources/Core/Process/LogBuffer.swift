import Foundation
import SwiftUI

/// Ring buffer of log lines published for live log views. Appends arrive from
/// pipe-reading threads; mutation happens on the main actor.
@MainActor
final class LogBuffer: ObservableObject {
    static let capacity = 5_000

    @Published private(set) var lines: [LogLine] = []
    private var nextId = 0

    struct LogLine: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    func append(_ text: String) {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lines.append(LogLine(id: nextId, text: String(raw)))
            nextId += 1
        }
        if lines.count > Self.capacity {
            lines.removeFirst(lines.count - Self.capacity)
        }
    }

    func clear() {
        lines.removeAll()
    }

    nonisolated func appendAsync(_ text: String) {
        Task { @MainActor in self.append(text) }
    }
}
