import AppKit
import SwiftUI

/// Terminates every managed server process before the app exits so no orphaned
/// `swift run` children keep holding ports.
final class SewnClientAppDelegate: NSObject, NSApplicationDelegate {
    static let shared = SewnClientAppDelegate()
    var shutdownHandler: (() -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shutdownHandler?()
        return .terminateNow
    }
}

struct SewnClientApp: App {
    @NSApplicationDelegateAdaptor(SewnClientAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1200, minHeight: 700)
        }
        .defaultSize(width: 1520, height: 920)
        .windowStyle(.titleBar)
        .commands {
            // Single-window app — remove New Window.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
