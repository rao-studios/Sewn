//
//  LocalVision.swift
//  Sewn
//
//  WHAT: On-device vision — one vision-language model in its own slot beside the chat
//        harness, answering `/v1/vision/look` and `/v1/vision/ontology` when a request asks
//        for `provider: local`. By default it is Rao's MLX conversion of Ministral 3 8B
//        Instruct (`ModelConfig.localVisionModel`), the model Veil used to load in its own
//        process: every Rao app now reads pictures through this one copy.
//  IN:   the two vision routes (never the chat path)
//  OUT:  one bounded answer per picture
//  PIN:  ITS OWN SLOT. The chat harness keeps its model and its gate. A batch of pictures
//        never evicts the chat model or waits behind a reply, and a reply never waits
//        behind a picture. The cost is memory — about ten gigabytes while pictures are
//        being read — so the model loads on the first picture and is let go after
//        `idleSeconds` with none.
//  PIN:  NEVER HOSTED. A local request this slot cannot answer fails; nothing here falls
//        back to a vendor.
//  PIN:  The picture is decoded the way Veil decodes it (ImageIO, EXIF orientation applied,
//        drawn into sRGB RGBA8), never handed to CoreImage as compressed bytes: decoded
//        lazily from a JPEG, a plain sRGB file once reached the model as something else.
//  PIN:  MLXLMCommon's UserInput/Chat names are SHADOWED in this module
//        (Sources/API/MLXModels): every MLX type here is fully qualified.
//

import Foundation
import Logging

/// Which vision model, from where: a Hub repo (pinned to a commit, or not), or a snapshot
/// directory already on this Mac — a conversion being checked before it is published.
struct LocalVisionModel: Sendable, Equatable, Hashable {
    enum Source: Sendable, Equatable, Hashable {
        case hub(id: String, revision: String?)
        case directory(URL)
    }

    let source: Source

    enum ParseError: Error, CustomStringConvertible, Equatable {
        case invalid(String)

        var description: String {
            switch self {
            case .invalid(let spec):
                return "\(spec) is not an on-device vision model: name org/repo, org/repo@revision, or an absolute snapshot directory."
            }
        }
    }

    /// `org/repo`, `org/repo@<revision>`, or an absolute directory. Nil or blank is
    /// `ModelConfig.localVisionModel`.
    static func parse(_ spec: String?) throws -> LocalVisionModel {
        let trimmed = (spec ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let spec = trimmed.isEmpty ? ModelConfig.localVisionModel : trimmed
        if spec.hasPrefix("/") {
            guard !spec.contains("/../"), !spec.hasSuffix("/..") else { throw ParseError.invalid(spec) }
            return LocalVisionModel(source: .directory(URL(fileURLWithPath: spec, isDirectory: true)))
        }
        let parts = spec.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let id = try? LocalModelStoreError.validated(parts[0]) else { throw ParseError.invalid(spec) }
        var revision: String?
        if parts.count > 1 {
            guard parts[1].range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
                throw ParseError.invalid(spec)
            }
            revision = parts[1]
        } else if id == ModelConfig.defaultLocalVisionModel {
            // The published conversion is always the pinned one unless a revision is named.
            revision = ModelConfig.defaultLocalVisionRevision
        }
        return LocalVisionModel(source: .hub(id: id, revision: revision))
    }

    /// What a catalogue entry records: the repo at its short commit, or the directory's name.
    var name: String {
        switch source {
        case .hub(let id, let revision): return revision.map { "\(id)@\($0.prefix(8))" } ?? id
        case .directory(let url): return url.lastPathComponent
        }
    }

    /// The Hub id, when there is one: what `/v1/providers/local/remove` must not delete.
    var hubID: String? {
        if case .hub(let id, _) = source { return id }
        return nil
    }
}

enum LocalVisionError: Error, CustomStringConvertible, Equatable {
    case unreadableImage
    case emptyAnswer
    case notASnapshot(String)

    var description: String {
        switch self {
        case .unreadableImage: return "The on-device vision model could not read the image."
        case .emptyAnswer: return "The on-device vision model returned no answer."
        case .notASnapshot(let path): return "\(path) holds no model snapshot (no config.json)."
        }
    }
}

extension LocalVision {
    /// Long side a picture is shown to the model at. The encoder works in 14-pixel patches,
    /// so this bounds both the time per picture and the tokens it costs.
    static let maxLongSide: Double = 1024
    /// An ontology may run longer than the hosted route's 900 tokens: here they cost only
    /// time, and an answer cut off mid-JSON is lost.
    static let ontologyMaxTokens = 1600
    /// The one more turn an ontology gets, in the same conversation, when its answer was
    /// not a usable JSON object.
    static let ontologyRetry = "That was not a valid JSON object of the shape asked for. Reply with only that JSON object — no code fences, no prose."
}

#if canImport(MLXVLM)

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import FrigateBridge
import ImageIO
import MLX
import MLXLMCommon
import MLXVLM

actor LocalVision {

    private let logger: Logger
    /// The store every download goes through (ModelProvider's): one fetch per model.
    private let models: LocalModelStore
    private let idleSeconds: TimeInterval
    /// Off only under `swift test`, where the running binary is not the bundle MLX loads
    /// its metallib beside.
    private let gpuPreflight: Bool

    private var resident: (model: LocalVisionModel, container: MLXLMCommon.ModelContainer)?
    private var loading: (model: LocalVisionModel, task: Task<MLXLMCommon.ModelContainer, Error>)?
    /// One picture at a time on this slot.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var idleRelease: Task<Void, Never>?

    init(
        logger: Logger, models: LocalModelStore,
        idleSeconds: TimeInterval = ModelConfig.localVisionIdleSeconds, gpuPreflight: Bool = true
    ) {
        self.logger = logger
        self.models = models
        self.idleSeconds = idleSeconds
        self.gpuPreflight = gpuPreflight
    }

    var isBuilt: Bool { true }

    /// The Hub id loaded or loading now, for the remove guard.
    var activeHubIDs: Set<String> {
        Set([resident?.model.hubID, loading?.model.hubID].compactMap { $0 })
    }

    /// "loading" | "ready" | "cold": whether the slot holds a model right now. The
    /// providers row carries it, so a client can say "loaded now" and keep Remove away.
    var stateName: String {
        if loading != nil { return "loading" }
        return resident != nil ? "ready" : "cold"
    }

    /// One answer about one picture: `instructions` as the system turn, `prompt` with the
    /// picture as the user turn, and — when `followUp` asks for it — one more turn in the
    /// same conversation. A fresh conversation per picture: one must not colour the next.
    func respond(
        image data: Data,
        instructions: String,
        prompt: String,
        model: LocalVisionModel,
        maxTokens: Int,
        temperature: Float,
        followUp: (@Sendable (String) -> String?)? = nil
    ) async throws -> String {
        await acquire()
        idleRelease?.cancel()
        idleRelease = nil
        defer {
            release()
            scheduleIdleRelease()
        }
        guard let picture = Self.decode(data) else { throw LocalVisionError.unreadableImage }
        let container = try await container(for: model)
        let session = MLXLMCommon.ChatSession(
            container, instructions: instructions,
            generateParameters: MLXLMCommon.GenerateParameters(maxTokens: maxTokens, temperature: temperature))
        let started = Date()
        var answer = try await session.respond(to: prompt, image: .ciImage(picture))
        if let next = followUp?(answer) {
            logger.info("[LocalVision] one more turn: the first answer was not usable")
            answer = try await session.respond(to: next)
        }
        logger.info("[LocalVision] answered with \(model.name) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalVisionError.emptyAnswer }
        return trimmed
    }

    /// Let the model go now; the next picture loads it again. Dropping the container only
    /// moves its ten gigabytes into MLX's buffer cache, which the process keeps: the cache is
    /// cleared so the memory goes back to the Mac. The chat model's weights are live arrays,
    /// not cache, and stay.
    func unload() {
        guard resident != nil || loading != nil else { return }
        let name = resident?.model.name
        resident = nil
        loading = nil
        idleRelease?.cancel()
        idleRelease = nil
        MLX.Memory.clearCache()
        if let name {
            logger.info("[LocalVision] released \(name); MLX now holds \(MLX.Memory.activeMemory / 1_048_576) MB active")
        }
    }

    // MARK: - The slot

    private func container(for model: LocalVisionModel) async throws -> MLXLMCommon.ModelContainer {
        if let resident, resident.model == model { return resident.container }
        if let loading, loading.model == model { return try await loading.task.value }
        guard !gpuPreflight || LocalGPU.report().isSatisfied else {
            throw ProviderUnavailable.localFailed(LocalGPU.remedy())
        }
        // Another model asked for: the one held is let go before the next loads.
        if resident != nil { logger.info("[LocalVision] swapping \(resident!.model.name) for \(model.name)") }
        resident = nil
        let models = self.models, logger = self.logger
        let task = Task<MLXLMCommon.ModelContainer, Error> {
            let directory: URL
            switch model.source {
            case .directory(let url):
                guard FileManager.default.fileExists(atPath: url.appending(path: "config.json").path(percentEncoded: false)) else {
                    throw LocalVisionError.notASnapshot(url.path(percentEncoded: false))
                }
                directory = url
            case .hub(let id, let revision):
                directory = try await models.download(
                    id: id, revision: revision, matching: LocalModelStore.patterns, useLatest: false,
                    progressHandler: { _ in })
            }
            logger.info("[LocalVision] loading \(model.name) from \(directory.path(percentEncoded: false))")
            return try await VLMModelFactory.shared.loadContainer(from: directory, using: HubTokenizerLoader())
        }
        loading = (model, task)
        do {
            let container = try await task.value
            if loading?.model == model { loading = nil }
            resident = (model, container)
            logger.info("[LocalVision] ready: \(model.name)")
            return container
        } catch {
            // A failed load is tried again by the next picture, not remembered.
            if loading?.model == model { loading = nil }
            logger.error("[LocalVision] \(model.name) failed to load: \(error)")
            throw error
        }
    }

    private func scheduleIdleRelease() {
        idleRelease?.cancel()
        guard resident != nil else { return }
        let seconds = idleSeconds
        idleRelease = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.releaseIfIdle()
        }
    }

    private func releaseIfIdle() {
        guard !busy, waiters.isEmpty else { return }
        unload()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    // MARK: - The picture

    /// Oriented, sRGB RGBA8, no larger than `maxLongSide` on its long side and never
    /// enlarged. Lanczos, not a plain affine scale: a phone photo shrinks four times, and
    /// aliased signage reads as other words.
    static func decode(_ data: Data) -> CIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return nil }
        // The full-size "thumbnail" is ImageIO's way of applying the EXIF orientation.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let drawn = sRGB(oriented)
        else { return nil }
        return bounded(CIImage(cgImage: drawn))
    }

    static func bounded(_ image: CIImage) -> CIImage {
        let longSide = max(image.extent.width, image.extent.height)
        guard longSide > maxLongSide else { return image }
        let scale = maxLongSide / longSide
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        return filter.outputImage ?? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private static func sRGB(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

#else

/// No MLX in this build: an honest refusal with the same surface.
actor LocalVision {
    init(logger: Logger, models: LocalModelStore, idleSeconds: TimeInterval = 0, gpuPreflight: Bool = true) {}
    var isBuilt: Bool { false }
    var activeHubIDs: Set<String> { [] }
    var stateName: String { "cold" }
    func respond(
        image data: Data, instructions: String, prompt: String, model: LocalVisionModel,
        maxTokens: Int, temperature: Float, followUp: (@Sendable (String) -> String?)? = nil
    ) async throws -> String {
        throw ProviderUnavailable.localNotBuilt
    }
    func unload() {}
}

#endif
