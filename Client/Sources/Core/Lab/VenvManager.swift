import Foundation
import SwiftUI

/// Manages the Python virtualenv that hosts the Tinker SDK, and runs the
/// bundled `tinker_helper.py` JSON bridge inside it.
@MainActor
final class VenvManager: ObservableObject {

    nonisolated static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SewnClient")
    }

    nonisolated static var venvURL: URL { appSupport.appendingPathComponent("tinker-venv") }
    nonisolated static var pythonURL: URL { venvURL.appendingPathComponent("bin/python3") }
    nonisolated static var runsURL: URL { appSupport.appendingPathComponent("runs") }
    nonisolated static var datasetsURL: URL { appSupport.appendingPathComponent("datasets") }

    enum State: Equatable {
        case unknown
        case missing
        case installing
        case ready(version: String)
        case broken(String)
    }

    @Published var state: State = .unknown
    let log = LogBuffer()

    /// Tinker API key for direct Lab use — mirrored from Sewn's .env when present.
    var apiKey: String {
        if let key = KeychainStore.get("tinker_api_key"), !key.isEmpty { return key }
        // Fallback: read from the Sewn repo's .env so one configuration serves both.
        let envPath = (SewnServerConfig.defaultRepoPath as NSString)
            .appendingPathComponent(".env")
        if let content = try? String(contentsOfFile: envPath, encoding: .utf8) {
            for line in content.components(separatedBy: .newlines)
            where line.hasPrefix("TINKER_API_KEY=") {
                return String(line.dropFirst("TINKER_API_KEY=".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    func detect() async {
        try? FileManager.default.createDirectory(at: Self.appSupport, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.runsURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.datasetsURL, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: Self.pythonURL.path) else {
            state = .missing
            return
        }
        let output = await runCapture(Self.pythonURL.path,
                                      ["-c", "import tinker; print(getattr(tinker, '__version__', 'installed'))"])
        if let version = output?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty,
           !version.contains("Error"), !version.contains("Traceback") {
            state = .ready(version: version)
        } else {
            state = .broken("tinker not importable — reinstall")
        }
    }

    func install() async {
        state = .installing
        log.clear()
        // 1. Create venv
        if !FileManager.default.fileExists(atPath: Self.pythonURL.path) {
            let created = await runStreaming("/usr/bin/env", ["python3", "-m", "venv", Self.venvURL.path])
            guard created else {
                state = .broken("venv creation failed — is python3 installed?")
                return
            }
        }
        // 2. Install SDK + cookbook
        let installed = await runStreaming(Self.pythonURL.path,
                                           ["-m", "pip", "install", "-U", "tinker", "tinker-cookbook"])
        guard installed else {
            state = .broken("pip install failed — see log")
            return
        }
        copyHelperIfNeeded(force: true)
        await detect()
    }

    /// Path to `tinker_helper.py` in App Support (copied from the bundle).
    func helperPath() -> String {
        copyHelperIfNeeded(force: false)
        return Self.appSupport.appendingPathComponent("tinker_helper.py").path
    }

    private func copyHelperIfNeeded(force: Bool) {
        let destination = Self.appSupport.appendingPathComponent("tinker_helper.py")
        guard force || !FileManager.default.fileExists(atPath: destination.path) else { return }
        guard let bundled = Bundle.module.url(forResource: "tinker_helper", withExtension: "py",
                                              subdirectory: "python") else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: bundled, to: destination)
    }

    // MARK: Process helpers

    /// Run and capture stdout (short commands).
    private func runCapture(_ executable: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Run with output streamed into the venv log. Returns success.
    private func runStreaming(_ executable: String, _ arguments: [String]) async -> Bool {
        let managed = ManagedProcess(log: log, ports: [])
        do {
            // ManagedProcess prefixes /usr/bin/env; pass the executable as arg 0.
            try managed.launch(
                arguments: executable == "/usr/bin/env" ? arguments : [executable] + arguments,
                workingDirectory: Self.appSupport
            )
        } catch {
            log.append("launch failed: \(error.localizedDescription)")
            return false
        }
        return await withCheckedContinuation { continuation in
            managed.onTermination = { status in
                continuation.resume(returning: status == 0)
            }
        }
    }
}
