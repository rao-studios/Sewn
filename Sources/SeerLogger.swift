//
//  SeerLogger.swift
//  seer-server
//
//  Created on 2/15/26.
//

import Foundation
import Logging

/// Serial queue for external log requests.
/// Ensures only one network request is in-flight at a time,
/// preserving order and preventing dropped events.
/// Serial queue for external log requests.
/// Ensures only one network request is in-flight at a time,
/// preserving order and preventing dropped events.
///
/// Uses a shared singleton so all `SeerLogger` instances
/// feed into the same serial queue.
actor ExternalLogQueue {
    static let shared: ExternalLogQueue = {
        let logger = Logger(label: "external-log-queue")
        let network = NetworkService(logger: logger, base: .supabase)
        return ExternalLogQueue(network: network)
    }()

    private let network: NetworkService
    private var pending: [Requests.Logger.Create] = []
    private var isProcessing = false

    private init(network: NetworkService) {
        self.network = network
    }

    func enqueue(_ request: Requests.Logger.Create) {
        pending.append(request)
        if !isProcessing {
            isProcessing = true
            Task { await processNext() }
        }
    }

    private func processNext() async {
        while !pending.isEmpty {
            let request = pending.removeFirst()
            do {
                _ = try await network.request(request)
            } catch {
                // Silently drop failed log pushes
                // print("Failed to log externally: \(error)")
            }
            // Throttle between requests to avoid rate-limiting
            try? await Task.sleep(nanoseconds: 120_000_000) // 120ms
        }
        isProcessing = false
    }
}

/// A lightweight wrapper around `Logger` that gates debug-level logging
/// behind `Sinatra.debugLogging` and supports an optional trailing closure
/// for custom post-log side effects.
///
/// Usage:
/// ```
/// logger.debug("⚜️ [Park] Saved") {
///     // custom code runs after the log statement
/// }
///
/// // With service filtering:
/// logger.debug("Searching...", service: .seer)
///
/// // With request tracing via SeerRequest:
/// logger.debug("Searching...", service: .seer, request: seerRequest)
///
/// // With cross-cutting flow tag (emits a second JSON line for the chat tab):
/// logger.info("GBT Result", "Trained...", service: .gbtTraining, request: req, flow: .chat)
/// ```
struct SeerLogger {
    /// Services that produce log output, allowing downstream filtering.
    /// Raw values map directly to the `service_name` Loki label that Alloy
    /// extracts from JSON log lines, so Cockpit drilldown tabs are keyed on these strings.
    enum ServicesType: String {
        case supabase    = "Supabase"
        case sinatra     = "Sinatra"
        case seer        = "Seer"
        case gita        = "Gita"
        case oracle      = "Oracle"
        case embedding   = "Embedding"
        case parking     = "Parking"
        case gbtTraining = "GBT Training"
        case startup     = "Start-up"
    }

    /// Cross-cutting flow tag for the `flow:` parameter on log calls.
    ///
    /// When set, a **second** JSON line is emitted with `service` replaced by the
    /// flow's service name so a single log call appears in both its own service tab
    /// AND a cross-cutting flow tab in Cockpit — without duplicating logic at call sites.
    ///
    /// - `.chat`: captures the full chat request journey (search → GBT → IMBHS → response).
    /// - `.embed(documentId:)`: captures one document's full indexing journey
    ///   (embedding → register → partition table → PQ → HNSW). The documentId is
    ///   added to the flow JSON line as `"documentId"` so it can be filtered in Grafana
    ///   Explore alongside requestId/ownerId via structured metadata.
    /// - `.frank(partitionId:)`: traces the full lifecycle of a single partition through
    ///   the Sinatra ML pipeline: retrieval → park → training → inference. The partitionId
    ///   is added to the flow JSON line so events for one content unit can be correlated
    ///   in Grafana Explore across all three stages regardless of which document it came from.
    enum SeerFlow {
        case chat
        case embed(documentId: String)
        case frank(partitionId: String)

        var serviceName: String {
            switch self {
            case .chat:  return "Flow: Chat"
            case .embed: return "Flow: Embed"
            case .frank: return "Flow: Frank"
            }
        }

        var documentId: String? {
            guard case .embed(let id) = self else { return nil }
            return id
        }

        var partitionId: String? {
            guard case .frank(let id) = self else { return nil }
            return id
        }
    }

    enum LogType: String {
        case trace
        case debug
        case info
        case notice
        case warning
        case error
        case critical
    }

    /// The underlying `Logger` instance. Use this when passing to APIs
    /// that expect a `Logging.Logger` (e.g. `FilePersistence`, `ModelProvider`).
    let base: Logger

    init(_ logger: Logger) {
        self.base = logger
    }

    /// Emits a structured JSON log line to stdout for Alloy to pick up.
    ///
    /// - Parameters:
    ///   - flow: When non-nil, a **second** JSON line is emitted under the flow's
    ///     service name so a single log call appears in both its own service tab AND
    ///     a cross-cutting flow tab in Cockpit. For `.embed(documentId:)` the second
    ///     line also carries a `"documentId"` field, which Alloy promotes to structured
    ///     metadata so it is filterable in Grafana Explore alongside requestId/ownerId.
    func externallyLog(
        name: String? = nil,
        message: String,
        eventType: LogType,
        externalOnly: Bool = false,
        seer: SeerRequest? = nil,
        service: ServicesType?,
        flow: SeerFlow? = nil
    ) {
        guard let service else { return }
        // Gate: ship info+ always; ship lower levels only when explicitly marked externalOnly.
        // info and above emit JSON to stdout so Alloy can extract the service_name label
        // for Cockpit drilldown tabs. debug/trace are excluded to keep stdout quiet.
        let isSignificant = eventType == .info || eventType == .notice ||
                            eventType == .warning || eventType == .error || eventType == .critical
        guard isSignificant || externalOnly else { return }

        var entry: [String: String] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "level": eventType.rawValue,
            "msg": message,
            "service": service.rawValue
        ]
        if let name { entry["event"] = name }
        if let requestID = seer?.requestID, !requestID.isEmpty { entry["requestId"] = requestID }
        if let ownerId = seer?.ownerId, !ownerId.isEmpty { entry["ownerId"] = ownerId }

        if let data = try? JSONSerialization.data(withJSONObject: entry),
           let line = String(data: data, encoding: .utf8) {
            print(line)
        }

        // If a cross-cutting flow is specified, re-emit the same entry under the flow
        // label so it also appears in the flow's Cockpit tab. For .embed flows the
        // documentId is included as an extra field so it can be filtered in Grafana.
        if let flow, flow.serviceName != service.rawValue {
            var flowEntry = entry
            flowEntry["service"] = flow.serviceName
            if let documentId = flow.documentId {
                flowEntry["documentId"] = documentId
            }
            if let partitionId = flow.partitionId {
                flowEntry["partitionId"] = partitionId
            }
            if let data = try? JSONSerialization.data(withJSONObject: flowEntry),
               let line = String(data: data, encoding: .utf8) {
                print(line)
            }
        }
    }

    // MARK: - Gated (only log when Sinatra.debugLogging is true)

    func trace(_ message: @autoclosure () -> Logger.Message,
               metadata: @autoclosure () -> Logger.Metadata? = nil,
               source: @autoclosure () -> String? = nil,
               service: ServicesType? = nil,
               request: SeerRequest? = nil,
               file: String = #fileID, function: String = #function, line: UInt = #line,
               then: (() -> Void)? = nil) {
        base.trace(message(), metadata: enrichedMetadata(service: service, requestID: request?.requestID, existing: metadata()), source: source(), file: file, function: function, line: line)
        then?()
    }

    func debug(_ label: String? = nil,
               _ message: @autoclosure () -> Logger.Message,
               metadata: @autoclosure () -> Logger.Metadata? = nil,
               source: @autoclosure () -> String? = nil,
               service: ServicesType? = nil,
               request: SeerRequest? = nil,
               externalOnly: Bool = false,
               flow: SeerFlow? = nil,
               file: String = #fileID, function: String = #function, line: UInt = #line,
               then: (() -> Void)? = nil) {
        if !externalOnly {
            base.debug(message(), metadata: enrichedMetadata(service: service, requestID: request?.requestID, existing: metadata()), source: source(), file: file, function: function, line: line)
        }
        externallyLog(name: label, message: message().description, eventType: .debug, externalOnly: externalOnly, seer: request, service: service, flow: flow)
        then?()
    }

    func info(_ label: String? = nil,
              _ message: @autoclosure () -> Logger.Message,
              metadata: @autoclosure () -> Logger.Metadata? = nil,
              source: @autoclosure () -> String? = nil,
              service: ServicesType? = nil,
              request: SeerRequest? = nil,
              externalOnly: Bool = false,
              flow: SeerFlow? = nil,
              file: String = #fileID, function: String = #function, line: UInt = #line,
              then: (() -> Void)? = nil) {
        if !externalOnly {
            base.info(message(), metadata: enrichedMetadata(service: service, requestID: request?.requestID, existing: metadata()), source: source(), file: file, function: function, line: line)
        }
        externallyLog(name: label, message: message().description, eventType: .info, externalOnly: externalOnly, seer: request, service: service, flow: flow)
        then?()
    }

    func notice(_ message: @autoclosure () -> Logger.Message,
                metadata: @autoclosure () -> Logger.Metadata? = nil,
                source: @autoclosure () -> String? = nil,
                service: ServicesType? = nil,
                request: SeerRequest? = nil,
                file: String = #fileID, function: String = #function, line: UInt = #line,
                then: (() -> Void)? = nil) {
        base.notice(message(), metadata: enrichedMetadata(service: service, requestID: request?.requestID, existing: metadata()), source: source(), file: file, function: function, line: line)
        then?()
    }

    // MARK: - Always forwarded (never gated)

    func warning(label: String? = nil,
                 _ message: @autoclosure () -> Logger.Message,
                 metadata: @autoclosure () -> Logger.Metadata? = nil,
                 source: @autoclosure () -> String? = nil,
                 service: ServicesType? = nil,
                 request: SeerRequest? = nil,
                 flow: SeerFlow? = nil,
                 file: String = #fileID, function: String = #function, line: UInt = #line,
                 then: (() -> Void)? = nil) {
        base.warning(message(), metadata: enrichedMetadata(service: service, requestID: request?.requestID, existing: metadata()), source: source(), file: file, function: function, line: line)
        externallyLog(name: label, message: message().description, eventType: .warning, seer: request, service: service, flow: flow)
        then?()
    }

    func error(_ label: String? = nil,
               _ message: @autoclosure () -> Logger.Message,
               metadata: @autoclosure () -> Logger.Metadata? = nil,
               source: @autoclosure () -> String? = nil,
               service: ServicesType? = nil,
               request: SeerRequest? = nil,
               flow: SeerFlow? = nil,
               file: String = #fileID, function: String = #function, line: UInt = #line,
               then: (() -> Void)? = nil) {
        base.error(message(), metadata: enrichedMetadata(service: service, requestID: request?.requestID, existing: metadata()), source: source(), file: file, function: function, line: line)
        externallyLog(name: label, message: message().description, eventType: .error, seer: request, service: service, flow: flow)
        then?()
    }

    func critical(_ message: @autoclosure () -> Logger.Message,
                  metadata: @autoclosure () -> Logger.Metadata? = nil,
                  source: @autoclosure () -> String? = nil,
                  service: ServicesType? = nil,
                  request: SeerRequest? = nil,
                  file: String = #fileID, function: String = #function, line: UInt = #line,
                  then: (() -> Void)? = nil) {
        base.critical(message(), metadata: enrichedMetadata(service: service, requestID: request?.requestID, existing: metadata()), source: source(), file: file, function: function, line: line)
        then?()
    }

    // MARK: - Private

    private func enrichedMetadata(service: ServicesType?, requestID: String?, existing: Logger.Metadata?) -> Logger.Metadata? {
        guard service != nil || requestID != nil else { return existing }
        var meta = existing ?? [:]
        if let service {
            meta["service"] = .string(service.rawValue)
        }
        if let requestID {
            meta["requestID"] = .string(requestID)
        }
        return meta
    }
}
