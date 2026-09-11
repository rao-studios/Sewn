import Foundation

/// Runs the bundled `tinker_helper.py` (venv python, TINKER_API_KEY injected)
/// and decodes its single-JSON-object output.
struct TinkerHelper {
    let pythonPath: String
    let helperPath: String
    let apiKey: String

    struct HelperError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Loosely-typed run/checkpoint records — the helper serializes SDK models
    /// whose exact fields evolve; the UI reads what it recognizes.
    typealias JSONObject = [String: AnyDecodable]

    func run(_ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: pythonPath)
                process.arguments = [helperPath] + arguments
                var environment = ProcessInfo.processInfo.environment
                environment["TINKER_API_KEY"] = apiKey
                process.environment = environment
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    if process.terminationStatus != 0 {
                        // Helper reports errors as {"error": ...} on stdout.
                        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let message = object["error"] as? String {
                            continuation.resume(throwing: HelperError(message: message))
                        } else {
                            let errorText = String(
                                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? "helper failed"
                            continuation.resume(throwing: HelperError(message: String(errorText.suffix(400))))
                        }
                        return
                    }
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Returns the `result` payload as loosely-typed JSON.
    func runJSON(_ arguments: [String]) async throws -> Any? {
        let data = try await run(arguments)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["result"]
    }
}

/// Type-erased Decodable for loosely-typed helper output.
struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let string = try? container.decode(String.self) { value = string }
        else if let array = try? container.decode([AnyDecodable].self) { value = array.map(\.value) }
        else if let object = try? container.decode([String: AnyDecodable].self) {
            value = object.mapValues(\.value)
        } else { value = NSNull() }
    }
}
