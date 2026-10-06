//
//  LocalModelStoreTests.swift
//  sewn-serverTests
//
//  The on-device models on this Mac's disk, as a client's model picker sees them:
//  GET /v1/providers/local/models, POST …/download and …/remove. The route tests
//  touch no network; the live test fetches, reports and removes one small model
//  in a scratch models home.
//
//  Live run:
//    SEWN_LOCAL_MODEL_STORE_TESTS=1 SEWN_LOCAL_MODEL_STORE_HOME=$(mktemp -d) \
//    swift test --filter LocalModelStoreLiveTests
//

import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import XCTest
@testable import sewn_server

final class LocalModelStoreRouteTests: XCTestCase {

    /// Mandatory: Sewn's models live in RaoStack's folder whatever HF_HOME says.
    func testTheModelsHomeIsRaosNeverHFHome() {
        XCTAssertEqual(LocalModels.home(["RAO_HOME": "/r", "HF_HOME": "/hf"]).path, "/r/models/huggingface")
        XCTAssertTrue(LocalModels.home(["HF_HOME": "/hf"]).path.hasSuffix("/.rao/models/huggingface"))
    }

    private func app() -> some ApplicationProtocol {
        let router = Router(context: SewnRequestContext.self)
        registerProvidersRoutes(router, modelProvider: ModelProvider(logger: Logger(label: "local-model-store-tests")))
        return Application(router: router)
    }

    private static func body(_ model: String) -> ByteBuffer {
        ByteBuffer(string: #"{"model":"\#(model)"}"#)
    }

    func testAnIDThatIsNotAHubIDIsRefusedBeforeTheDisk() async throws {
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/providers/local/models?ids=../etc", method: .get) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
            for route in ["/v1/providers/local/download", "/v1/providers/local/remove"] {
                try await client.execute(uri: route, method: .post, body: Self.body("a/../../b")) { response in
                    XCTAssertEqual(response.status, .badRequest, route)
                }
            }
        }
    }

    func testTheDefaultAndTheModelInUseAreNeverRemoved() async throws {
        #if canImport(MLXLLM)
        let chosen = "mlx-community/Ministral-3-8B-Instruct-2512-4bit"
        ModelConfig.chooseLocalModel(chosen)
        defer { ModelConfig.chooseLocalModel(nil) }
        try await app().test(.router) { client in
            for model in [ModelConfig.defaultLocalModel, chosen] {
                try await client.execute(uri: "/v1/providers/local/remove", method: .post, body: Self.body(model)) { response in
                    XCTAssertEqual(response.status, .conflict, model)
                }
            }
        }
        #endif
    }

    func testAModelThatWasNeverFetchedIsAbsent() async throws {
        #if canImport(MLXLLM)
        let id = "rao-tests/never-downloaded-\(UUID().uuidString.prefix(8))"
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/providers/local/models?ids=\(id)", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let models = try JSONDecoder().decode(LocalModelsResponse.self, from: Data(buffer: response.body)).models
                XCTAssertEqual(models, [LocalModelInfo(id: id, disk: .absent)])
            }
        }
        #endif
    }
}

#if canImport(MLXLLM)
final class LocalModelStoreLiveTests: XCTestCase {

    /// Fetch a small model, see it reported while it downloads and then as on disk, remove it.
    func testAModelIsFetchedReportedAndRemoved() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SEWN_LOCAL_MODEL_STORE_TESTS"] == "1", "set SEWN_LOCAL_MODEL_STORE_TESTS=1 and SEWN_LOCAL_MODEL_STORE_HOME")
        let path = try XCTUnwrap(env["SEWN_LOCAL_MODEL_STORE_HOME"], "SEWN_LOCAL_MODEL_STORE_HOME must name a scratch folder")
        XCTAssertFalse(path.contains("/.rao/"), "use a scratch folder, not the real models home")
        let home = URL(fileURLWithPath: path)
        let id = env["SEWN_LOCAL_MODEL_STORE_MODEL"] ?? "mlx-community/SmolLM-135M-Instruct-4bit"
        let store = LocalModelStore(logger: Logger(label: "local-model-store-live"), home: home)

        let before = await store.disk(id)
        XCTAssertEqual(before, .absent)
        // Settings starts the download; a load of the same model (the harness's downloader is
        // this store) joins it rather than fetching again, and hears its progress.
        try await store.download(id)
        let joined = await store.disk(id)
        guard case .downloading = joined else { return XCTFail("expected a download running, got \(joined)") }
        let heard = LockedValue(0)
        let loaded = try await store.download(
            id: id, revision: nil, matching: LocalModelStore.patterns, useLatest: false,
            progressHandler: { _ in heard.withLock { $0 += 1 } })
        XCTAssertEqual(loaded.path, home.appending(path: "snapshots/models/\(id)").path)
        XCTAssertGreaterThan(heard.withLock { $0 }, 0, "a joined load hears the download's progress")
        let fetched = await store.disk(id)
        XCTAssertEqual(fetched, .installed)
        // One copy, inside the home: the snapshot, and no Hub blob cache beside it.
        let snapshot = await store.directory(of: id)
        XCTAssertEqual(snapshot?.path, home.appending(path: "snapshots/models/\(id)").path)
        let cached = home.appending(path: "hub").appending(path: "models--" + id.replacingOccurrences(of: "/", with: "--"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path(percentEncoded: false)))

        // A failure on record never hides a copy now on disk.
        let missing = "rao-tests/no-such-model-\(UUID().uuidString.prefix(8).lowercased())"
        try await store.download(missing)
        for _ in 0..<120 {
            if case .failed = await store.disk(missing) { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard case .failed = await store.disk(missing) else { return XCTFail("a missing repo should fail") }
        let fake = home.appending(path: "snapshots/models/\(missing)")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        for name in ["config.json", "tokenizer.json", "model.safetensors"] {
            try Data("{}".utf8).write(to: fake.appending(path: name))
        }
        let healed = await store.disk(missing)
        XCTAssertEqual(healed, .installed)
        try FileManager.default.removeItem(at: home.appending(path: "snapshots/models/rao-tests"))

        try await store.remove(id, inUse: [], kept: ModelConfig.defaultLocalModel)
        let after = await store.disk(id)
        XCTAssertEqual(after, .absent)
        let gone = await store.directory(of: id)
        XCTAssertNil(gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path(percentEncoded: false)))
    }
}
#endif
