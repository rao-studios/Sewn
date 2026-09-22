//
//  DataDirectoryTests.swift
//  sewn-serverTests
//
//  The storage root is process-wide and set once at startup from
//  `--data-dir` / `SEWN_DATA_DIR`. These tests prove the seam: configure
//  moves every FilePersistence and node-id under the chosen directory, and
//  nil restores the default. Reset in tearDown so other tests keep their root.
//

import Foundation
import Logging
import XCTest
@testable import sewn_server

final class DataDirectoryTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sewn-data-dir-\(UUID().uuidString)")
    }

    override func tearDown() {
        FilePersistence.configure(dataDirectory: nil)
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testConfigureMovesTheRootAndCreatesIt() {
        let root = FilePersistence.configure(dataDirectory: tempRoot.path)
        XCTAssertEqual(root.standardizedFileURL.path, tempRoot.standardizedFileURL.path)
        XCTAssertEqual(FilePersistence.getDefaultURL().standardizedFileURL.path, tempRoot.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.path))

        let store = FilePersistence(key: "probe/value", kind: .basic, logger: Logger(label: "test"))
        XCTAssertTrue(store.url.path.hasPrefix(tempRoot.standardizedFileURL.path))
        store.save(state: ["hello": 1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
    }

    /// A root with a space, like a shared stack's `~/Library/Application Support/…/sewn-db`:
    /// save must create the file, restore must read it back, and a nested key
    /// must land too.
    func testARootWithASpacePersistsAndRestores() {
        let spaced = tempRoot.appendingPathComponent("Application Support/sewn-db")
        FilePersistence.configure(dataDirectory: spaced.path)
        let logger = Logger(label: "test")

        let table = FilePersistence(key: "registry-probe", kind: .basic, logger: logger)
        table.save(state: ["hello": 1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: table.url.path(percentEncoded: false)), "created under the real path")
        let restored: [String: Int]? = FilePersistence(key: "registry-probe", kind: .basic, logger: logger).restore()
        XCTAssertEqual(restored, ["hello": 1])

        let nestedKey = "sinatra/owner abc/A+B@v1-parts"
        let nested = FilePersistence(key: nestedKey, kind: .basic, logger: logger)
        nested.save(state: ["x"])
        table.save(state: ["hello": 2])   // the overwrite path
        let again: [String: Int]? = FilePersistence(key: "registry-probe", kind: .basic, logger: logger).restore()
        XCTAssertEqual(again, ["hello": 2])
        let nestedBack: [String]? = FilePersistence(key: nestedKey, kind: .basic, logger: logger).restore()
        XCTAssertEqual(nestedBack, ["x"])
    }

    func testTildeIsExpanded() {
        let root = FilePersistence.configure(dataDirectory: "~/sewn-data-dir-tilde-probe")
        XCTAssertFalse(root.path.contains("~"))
        XCTAssertTrue(root.path.hasPrefix(NSHomeDirectory()))
        try? FileManager.default.removeItem(at: root)
    }

    func testNodeIdentityLivesUnderTheConfiguredRoot() {
        FilePersistence.configure(dataDirectory: tempRoot.path)
        let first = NodeIdentity.load(logger: Logger(label: "test"))
        let second = NodeIdentity.load(logger: Logger(label: "test"))
        XCTAssertEqual(first.nodeId, second.nodeId, "a fresh root must keep a stable identity")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("node-id").path))
    }

    func testNilRestoresTheDefault() {
        FilePersistence.configure(dataDirectory: tempRoot.path)
        FilePersistence.configure(dataDirectory: nil)
        XCTAssertTrue(FilePersistence.getDefaultURL().path.hasSuffix("/Documents/sewn-db"))
    }
}
