//
//  LocalModelStore.swift
//  Sewn
//
//  WHAT: The on-device models on this Mac's disk — whether one is there, fetching one
//        without loading it, and removing one — for a client's model picker (Ambient's
//        Settings › On-device).
//  IN:   GET /v1/providers/local/models, POST …/local/download, POST …/local/remove
//  PIN:  "On disk" and the download are FrigateBridge's HubDownloader(home:), the same lookup
//        and fetch a load makes (LocalInference hands the harness the same downloader):
//        whatever this reports as on disk loads without a download, and a download lands
//        where the next load looks.
//  PIN:  THE HOME IS ~/.rao, MANDATORY. `LocalModels.home` is RaoStack's models folder —
//        RAO_HOME's, else ~/.rao's — never HF_HOME and never Frigate's default
//        (~/.cache/huggingface): every Rao app finds a model where Sewn put it.
//

import Foundation
import Logging
import RaoStack

/// Where this Mac's on-device models live.
enum LocalModels {
    /// `<rao home>/models/huggingface`: RAO_HOME's when a launcher or a test names one,
    /// else ~/.rao's. `HF_HOME` (and Sewn config's `hfHome`) does not move it.
    static func home(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        RaoHome.resolved(environment).huggingFaceHome
    }
}

/// One model's place on this Mac.
enum LocalModelDisk: Sendable, Equatable {
    case absent
    case downloading(Double)
    case installed
    case failed(String)

    var name: String {
        switch self {
        case .absent: return "absent"
        case .downloading: return "downloading"
        case .installed: return "installed"
        case .failed: return "failed"
        }
    }
}

enum LocalModelStoreError: Error, CustomStringConvertible, Equatable {
    case invalidID(String)
    case inUse(String)
    case keptModel(String)
    case downloading(String)
    case unavailable

    var description: String {
        switch self {
        case .invalidID(let id): return "\(id) is not an on-device model id."
        case .inUse(let id): return "\(id) is the on-device model in use; choose another before removing it."
        case .keptModel(let id): return "\(id) is the default on-device model and stays on this Mac."
        case .downloading(let id): return "\(id) is still downloading."
        case .unavailable: return ProviderUnavailable.localNotBuilt.description
        }
    }

    /// `org/name`: letters, digits, `.`, `_` and `-`, never a path that climbs out.
    static func validated(_ id: String) throws -> String {
        let part = #"[A-Za-z0-9][A-Za-z0-9._-]*"#
        guard id.range(of: "^\(part)/\(part)$", options: .regularExpression) != nil,
            !id.contains("..")
        else { throw LocalModelStoreError.invalidID(id) }
        return id
    }
}

#if canImport(MLXLLM)

import FrigateBridge
import MLXLMCommon

actor LocalModelStore: Downloader {

    /// What a load fetches: weights, configs and tokenizer, and a chat template file.
    static let patterns = ["*.safetensors", "*.json", "*.jinja"]

    private let logger: Logger
    /// `LocalModels.home()`, or a test's scratch folder.
    let home: URL
    /// One fetch per model at a time, whoever asked — Settings' Download or the harness's load
    /// (this store is the harness's downloader): two HubApi fetches of one model delete each
    /// other's partial files.
    private var fetches: [String: Task<URL, Error>] = [:]
    private var progress: [String: Double] = [:]
    /// Everyone waiting on a fetch hears its progress, so a load that joined a Settings
    /// download still moves (Ambient's warm waits only while progress moves).
    private var listeners: [String: [@Sendable (Progress) -> Void]] = [:]
    private var failures: [String: String] = [:]

    init(logger: Logger, home: URL = LocalModels.home()) {
        self.logger = logger
        self.home = home
    }

    /// Downloading, then what is on disk, then a failure: a model that failed once and was
    /// fetched since (by a load) is installed.
    func disk(_ id: String) -> LocalModelDisk {
        if fetches[id] != nil { return .downloading(progress[id] ?? 0) }
        if directory(of: id) != nil { return .installed }
        if let failure = failures[id] { return .failed(failure) }
        return .absent
    }

    /// Fetch without loading (Settings › On-device). Joins a fetch already running.
    func download(_ id: String) throws {
        let id = try LocalModelStoreError.validated(id)
        failures[id] = nil
        guard fetches[id] == nil, directory(of: id) == nil else { return }
        _ = fetch(id, revision: nil, patterns: Self.patterns, useLatest: false)
    }

    // MARK: Downloader — the harness's loads come through here too

    func download(
        id: String, revision: String?, matching patterns: [String], useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        listeners[id, default: []].append(progressHandler)
        return try await fetch(id, revision: revision, patterns: patterns, useLatest: useLatest).value
    }

    /// The one fetch of `id`: the one running, or a new one. A copy already on disk is
    /// returned at once by HubDownloader's own lookup.
    private func fetch(_ id: String, revision: String?, patterns: [String], useLatest: Bool) -> Task<URL, Error> {
        if let running = fetches[id] { return running }
        progress[id] = 0
        logger.info("[local] fetching \(id) into \(home.path(percentEncoded: false))")
        let home = self.home
        let task = Task<URL, Error> {
            do {
                let url = try await HubDownloader(home: home).download(
                    id: id, revision: revision, matching: patterns, useLatest: useLatest,
                    progressHandler: { fraction in
                        let completed = fraction.fractionCompleted
                        Task { await self.note(id, completed) }
                    })
                self.finish(id, failure: nil)
                return url
            } catch {
                self.finish(id, failure: String(describing: error))
                throw error
            }
        }
        fetches[id] = task
        return task
    }

    /// Delete every copy of `id` a load would find, and any Hub cache copy an earlier build's
    /// download left beside it (those kept the weights twice). `inUse` is the
    /// model Sewn would run on-device right now, `kept` the default other apps expect on disk.
    func remove(_ id: String, inUse: Set<String>, kept: String) throws {
        let id = try LocalModelStoreError.validated(id)
        guard id != kept else { throw LocalModelStoreError.keptModel(id) }
        guard !inUse.contains(id) else { throw LocalModelStoreError.inUse(id) }
        guard fetches[id] == nil else { throw LocalModelStoreError.downloading(id) }
        // Only this store's own folders: the lookup also reads the Rao stack's, which a store
        // pointed elsewhere (a test's scratch home) must never delete from.
        let snapshots = HubDownloader.ownRoots(home: home).map { $0.appending(path: "models").appending(path: id) }
        let cached = home.appending(path: "hub").appending(path: "models--" + id.replacingOccurrences(of: "/", with: "--"))
        for directory in snapshots + [cached] {
            guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { continue }
            try FileManager.default.removeItem(at: directory)
            logger.info("[local] removed \(directory.path(percentEncoded: false))")
        }
        failures[id] = nil
    }


    private func note(_ id: String, _ fraction: Double) {
        guard fetches[id] != nil, fraction.isFinite else { return }
        progress[id] = max(progress[id] ?? 0, fraction)
        let report = Progress(totalUnitCount: 1_000)
        report.completedUnitCount = Int64((progress[id] ?? 0) * 1_000)
        for listener in listeners[id] ?? [] { listener(report) }
    }

    private func finish(_ id: String, failure: String?) {
        fetches[id] = nil
        progress[id] = nil
        listeners[id] = nil
        if let failure {
            failures[id] = failure
            logger.error("[local] fetch \(id) failed: \(failure)")
        } else {
            failures[id] = nil
            logger.info("[local] fetched \(id)")
        }
    }

    /// The complete copy a load would use, under the home.
    func directory(of id: String) -> URL? {
        HubDownloader.materializedSnapshot(id: id, matching: Self.patterns, roots: HubDownloader.snapshotRoots(home: home))
    }
}

#else

/// No MLX in this build: nothing is on disk, and nothing downloads.
actor LocalModelStore {
    init(logger: Logger, home: URL = LocalModels.home()) {}
    func disk(_ id: String) -> LocalModelDisk { .failed(ProviderUnavailable.localNotBuilt.description) }
    func download(_ id: String) throws { throw LocalModelStoreError.unavailable }
    func remove(_ id: String, inUse: Set<String>, kept: String) throws { throw LocalModelStoreError.unavailable }
}

#endif
