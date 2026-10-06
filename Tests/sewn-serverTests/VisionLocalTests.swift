//
//  VisionLocalTests.swift
//  sewn-serverTests
//
//  Pictures on this Mac: which model a request names and how it reads, the wire's new
//  provider and model fields, the capability the providers list reports, and the picture
//  as the model is shown it. Nothing here loads a model; `VisionLocalLiveTests` does.
//

import Foundation
import XCTest
@testable import sewn_server

#if canImport(MLXVLM)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

final class VisionLocalTests: XCTestCase {

    // MARK: - Which model

    func testNamingNothingIsThePinnedConversion() throws {
        guard ProcessInfo.processInfo.environment["SEWN_LOCAL_VISION_MODEL"] == nil else {
            throw XCTSkip("SEWN_LOCAL_VISION_MODEL is set in this environment")
        }
        let model = try LocalVisionModel.parse(nil)
        XCTAssertEqual(model.source, .hub(id: ModelConfig.defaultLocalVisionModel,
                                          revision: ModelConfig.defaultLocalVisionRevision))
        XCTAssertEqual(model.name, "rao-studios/Ministral-3-8B-Instruct-2512-mlx-8bit@3d71052d",
                       "what Veil's catalogue entries recorded before the model moved to Sewn")
        XCTAssertEqual(try LocalVisionModel.parse("   "), model)
        XCTAssertEqual(try LocalVisionModel.parse(ModelConfig.defaultLocalVisionModel), model,
                       "the published conversion is the pinned one unless a revision is named")
    }

    func testAHubIDARevisionAndADirectory() throws {
        XCTAssertEqual(try LocalVisionModel.parse("org/model").source, .hub(id: "org/model", revision: nil))
        XCTAssertEqual(try LocalVisionModel.parse("org/model@abc123").source, .hub(id: "org/model", revision: "abc123"))
        XCTAssertEqual(try LocalVisionModel.parse("/Volumes/T9/models/vlm/x").source,
                       .directory(URL(fileURLWithPath: "/Volumes/T9/models/vlm/x", isDirectory: true)))
        XCTAssertEqual(try LocalVisionModel.parse("/Volumes/T9/models/vlm/x").name, "x")
        XCTAssertEqual(try LocalVisionModel.parse("org/model@abc123").hubID, "org/model")
        XCTAssertNil(try LocalVisionModel.parse("/tmp/x").hubID)
    }

    func testWhatIsNotAModelIsRefused() {
        for spec in ["not a model", "model", "org/../x", "../org/x", "org/model@", "org/model@a b",
                     "/tmp/../etc", "~/models/x", "./x"] {
            XCTAssertThrowsError(try LocalVisionModel.parse(spec), spec)
        }
    }

    // MARK: - The wire

    func testTheVisionRequestsCarryAProviderAndAModel() throws {
        let look = try JSONDecoder().decode(VisionLookRequest.self, from: Data(#"""
            {"image":"AA==","media_type":"image/png","mode":"describe","provider":"local","model":"org/model@abc"}
            """#.utf8))
        XCTAssertEqual(look.provider, .local)
        XCTAssertEqual(look.model, "org/model@abc")
        let ontology = try JSONDecoder().decode(VisionOntologyRequest.self, from: Data(#"""
            {"image":"AA==","media_type":"image/jpeg","provider":"mistral"}
            """#.utf8))
        XCTAssertEqual(ontology.provider, .mistral)
        XCTAssertNil(ontology.model)
    }

    func testAClientFromBeforeNamesNeither() throws {
        let look = try JSONDecoder().decode(VisionLookRequest.self, from: Data(#"""
            {"image":"AA==","media_type":"image/png","mode":"describe"}
            """#.utf8))
        XCTAssertNil(look.provider)
        XCTAssertNil(look.model)
        let ontology = try JSONDecoder().decode(VisionOntologyRequest.self, from: Data(#"""
            {"image":"AA==","media_type":"image/png","hint":"cover art"}
            """#.utf8))
        XCTAssertNil(ontology.provider)
    }

    func testBothLanesSpendTheSameBudgetOnALook() {
        XCTAssertEqual(visionLookMaxTokens(mode: "describe"), 800)
        XCTAssertEqual(visionLookMaxTokens(mode: "design_plan"), 4096)
        XCTAssertGreaterThan(LocalVision.ontologyMaxTokens, 900, "an answer cut off mid-JSON is lost")
    }

    // MARK: - The providers list

    func testOnlyTheLocalRowReportsVision() {
        let local = providerInfo(.local, localState: .cold, localBuilt: true, visionBuilt: true)
        XCTAssertTrue(local.capabilities.vision)
        XCTAssertFalse(providerInfo(.local, localState: .cold, localBuilt: true, visionBuilt: false).capabilities.vision)
        XCTAssertFalse(providerInfo(.mistral, localState: .cold, localBuilt: true, visionBuilt: true).capabilities.vision)
        XCTAssertEqual(local.visionModel, try LocalVisionModel.parse(nil).name, "the local row names it")
        XCTAssertNil(providerInfo(.mistral, localState: .cold, localBuilt: true, visionBuilt: true).visionModel)
        XCTAssertEqual(providerInfo(.local, localState: .cold, localBuilt: true, visionBuilt: true,
                                    visionState: "ready").visionState, "ready", "a client can say \"loaded now\"")
        XCTAssertNil(providerInfo(.mistral, localState: .cold, localBuilt: true, visionBuilt: true,
                                  visionState: "ready").visionState)
    }

    // MARK: - The picture

    #if canImport(MLXVLM)
    private func png(width: Int, height: Int) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testALargePictureIsShownAtTheBoundAndASmallOneAsItIs() throws {
        let large = try XCTUnwrap(LocalVision.decode(try png(width: 3000, height: 1500)))
        XCTAssertEqual(max(large.extent.width, large.extent.height), LocalVision.maxLongSide, accuracy: 2)
        let small = try XCTUnwrap(LocalVision.decode(try png(width: 640, height: 480)))
        XCTAssertEqual(small.extent.size, CGSize(width: 640, height: 480), "never enlarged")
    }

    func testBytesThatAreNoPictureAreRefused() {
        XCTAssertNil(LocalVision.decode(Data("not a picture".utf8)))
        XCTAssertNil(LocalVision.decode(Data()))
    }
    #endif
}
