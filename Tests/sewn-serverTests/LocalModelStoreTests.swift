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
        try await store.download(id)
        var sawDownloading = false
        for _ in 0..<600 {
            let disk = await store.disk(id)
            if case .downloading = disk { sawDownloading = true }
            if disk == .installed { break }
            if case .failed(let reason) = disk { XCTFail(reason); return }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertTrue(sawDownloading)
        let fetched = await store.disk(id)
        XCTAssertEqual(fetched, .installed)
        // Both copies a download makes are inside the home: the snapshot and the Hub's cache.
        let snapshot = await store.directory(of: id)
        XCTAssertEqual(snapshot?.path, home.appending(path: "snapshots/models/\(id)").path)
        let cached = home.appending(path: "hub").appending(path: "models--" + id.replacingOccurrences(of: "/", with: "--"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path(percentEncoded: false)))

        try await store.remove(id, inUse: [], kept: ModelConfig.defaultLocalModel)
        let after = await store.disk(id)
        XCTAssertEqual(after, .absent)
        let gone = await store.directory(of: id)
        XCTAssertNil(gone)
        // The Hub cache keeps a second copy of every file; removal frees it too.
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path(percentEncoded: false)))
    }
}
#endif
