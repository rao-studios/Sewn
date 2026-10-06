//
//  VisionLocalLiveTests.swift
//  sewn-serverTests
//
//  The real on-device vision model, loaded once and asked twice: a look and a catalogue
//  entry for one synthetic picture. And, with MLXVLM now linked into Sewn, the chat
//  harness still loading chat models as text models — a `mistral3` checkpoint included,
//  which MLXLMCommon's registry would otherwise hand to the VLM factory first.
//  Off by default — the models are many gigabytes.
//
//  Run (copy mlx.metallib into the built xctest bundle first; see scripts/build-metallib.sh):
//    SEWN_LOCAL_VISION_TESTS=1 [SEWN_LOCAL_VISION_MODEL=org/repo@rev | /abs/dir] \
//    swift test --filter VisionLocalLiveTests
//

import Foundation
import Logging
import XCTest
@testable import sewn_server

#if canImport(MLXVLM)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

final class VisionLocalLiveTests: XCTestCase {

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["SEWN_LOCAL_VISION_TESTS"] == "1" else {
            throw XCTSkip("set SEWN_LOCAL_VISION_TESTS=1 to load the on-device vision model")
        }
    }

    /// A red disc on white, with a black bar under it.
    private func picture() throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        context.setFillColor(red: 0.85, green: 0.05, blue: 0.05, alpha: 1)
        context.fillEllipse(in: CGRect(x: 250, y: 200, width: 300, height: 300))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 200, y: 80, width: 400, height: 60))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testOneModelLooksAndCatalogues() async throws {
        let logger = Logger(label: "vision-local-live")
        let vision = LocalVision(
            logger: logger, models: LocalModelStore(logger: logger), idleSeconds: 60, gpuPreflight: false)
        let image = try picture().base64EncodedString()

        let started = Date()
        let (look, model) = try await localVisionAnswer(
            image: image, model: nil, vision: vision, logger: logger,
            instructions: visionLookSystemPrompt(mode: "describe", authoringContract: nil),
            prompt: visionLookUserText(pageTitle: nil, pageText: nil, direction: nil),
            maxTokens: visionLookMaxTokens(mode: "describe"), temperature: 0.2)
        print("[live] \(model.name) look in \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(look)")
        XCTAssertFalse(look.isEmpty)
        XCTAssertTrue(look.lowercased().contains("red") || look.lowercased().contains("circle"), look)

        let again = Date()
        let body = VisionOntologyRequest(image: image, mediaType: "image/png", hint: "a test card", provider: .local)
        let ontology = try await localVisionOntology(body, vision: vision, logger: logger)
        print("[live] ontology in \(String(format: "%.1f", Date().timeIntervalSince(again)))s (model resident): \(ontology)")
        XCTAssertFalse(ontology.caption.isEmpty)
        XCTAssertEqual(ontology.model, model.name)
        await vision.unload()
    }

    func testTheChatHarnessStillLoadsTextModels() async throws {
        let logger = Logger(label: "vision-local-live")
        let store = FileManager.default.temporaryDirectory.appending(path: "sewn-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: store) }
        let local = LocalInference(
            logger: logger, storeDirectory: store, gpuPreflight: false, models: LocalModelStore(logger: logger))
        // Nemo (`mistral`), then Rao's Ministral conversion (`mistral3`, vision tower and all)
        // asked for as a chat model: both must answer through the text factory.
        for modelID in [ModelConfig.defaultLocalModel, ModelConfig.defaultLocalVisionModel] {
            let reply = try await local.generate(
                system: "Answer in one word.",
                messages: [.init(role: "user", content: "Say OK.")],
                tools: nil, modelID: modelID, maxTokens: 8)
            print("[live] chat \(modelID): \(reply.text)")
            XCTAssertFalse(reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, modelID)
        }
        await local.flush()
    }
}
#endif
