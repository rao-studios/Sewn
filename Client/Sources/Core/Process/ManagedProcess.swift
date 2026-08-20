import Foundation

/// Wraps a Foundation `Process` running a long-lived command (e.g. `swift run
/// seer-server …` inside a repo checkout), capturing stdout/stderr into a
/// `LogBuffer` and providing graceful stop with a port-sweep fallback.
///
/// `swift run` spawns the real server as a child process, so SIGTERM on the
/// `swift` frontend may leave the server alive — `stop()` follows up by killing
/// whatever still listens on the process's declared ports.
final class ManagedProcess: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    let log: LogBuffer
    /// Ports this process is expected to bind — used for the kill sweep.
    let ports: [Int]

    private(set) var launchDate: Date?
    var onTermination: ((Int32) -> Void)?

    var isRunning: Bool { process.isRunning }
    var pid: Int32? { process.isRunning ? process.processIdentifier : nil }

    /// PATH from the user's login shell, resolved once — `swift` usually lives
    /// in Xcode's toolchain which isn't on the GUI-app default PATH.
    private static let loginPath: String = {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "echo $PATH"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        try? probe.run()
        probe.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? "/usr/bin:/bin:/usr/local/bin" : path
    }()

    init(log: LogBuffer, ports: [Int]) {
        self.log = log
        self.ports = ports
    }

    func launch(
        arguments: [String],
        workingDirectory: URL,
        extraEnvironment: [String: String] = [:]
    ) throws {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.loginPath
        for (key, value) in extraEnvironment { environment[key] = value }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let logBuffer = log
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            logBuffer.appendAsync(text)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            logBuffer.appendAsync(text)
        }

        process.terminationHandler = { [weak self] proc in
            self?.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self?.stderrPipe.fileHandleForReading.readabilityHandler = nil
            self?.log.appendAsync("── process exited (status \(proc.terminationStatus)) ──")
            self?.onTermination?(proc.terminationStatus)
        }

        log.appendAsync("$ \(arguments.joined(separator: " "))  [cwd: \(workingDirectory.path)]")
        try process.run()
        launchDate = Date()
    }

    /// Graceful stop: SIGTERM the frontend, wait up to `grace`, then sweep the
    /// declared ports for surviving children (the actual server under `swift run`).
    func stop(grace: TimeInterval = 5) async {
        guard process.isRunning else {
            Self.killListeners(on: ports)
            return
        }
        process.terminate()

        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        Self.killListeners(on: ports)
    }

    /// Stops any process listening on the given ports (children `swift run`
    /// left behind — the actual server is a child of the swift frontend, so
    /// terminating the frontend never signals it).
    ///
    /// Graceful-first: SIGTERM so the server's shutdown flush runs (Totems
    /// persist their partition table on SIGTERM — a straight `kill -9` here
    /// was silently discarding documents indexed since the last flush), then
    /// SIGKILL only what survives the grace window.
    static func killListeners(on ports: [Int], grace: TimeInterval = 6) {
        var pids = listenerPids(on: ports)
        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGTERM) }

        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            pids = listenerPids(on: ports)
            if pids.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        for pid in listenerPids(on: ports) { kill(pid, SIGKILL) }
    }

    private static func listenerPids(on ports: [Int]) -> [Int32] {
        var pids = Set<Int32>()
        for port in ports {
            let sweep = Process()
            let stdout = Pipe()
            sweep.executableURL = URL(fileURLWithPath: "/bin/zsh")
            sweep.arguments = ["-c", "lsof -ti :\(port) 2>/dev/null"]
            sweep.standardOutput = stdout
            guard (try? sweep.run()) != nil else { continue }
            sweep.waitUntilExit()
            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            for line in output.split(separator: "\n") {
                if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                    pids.insert(pid)
                }
            }
        }
        return Array(pids)
    }
}
