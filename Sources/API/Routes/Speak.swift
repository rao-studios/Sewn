import Foundation
import Hummingbird
import Logging
import NIOCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Models

struct SpeakRequest: Codable {
    let input: String
    let model: String
    let voiceId: String
    let responseFormat: String?
    let stream: Bool?

    enum CodingKeys: String, CodingKey {
        case input
        case model
        case voiceId        = "voice_id"
        case responseFormat = "response_format"
        case stream
    }
}

// MARK: - Route Registration

func registerSpeakRoute(_ router: some RouterMethods<SewnRequestContext>) {
    router.post("/v1/speak") { request, context async throws -> Response in
        let speakReq = try await request.decode(as: SpeakRequest.self, context: context)
        context.logger.info("[Speak] TTS — model: \(speakReq.model), voice: \(speakReq.voiceId)")
        return try await proxySpeakToMistral(speakReq: speakReq, logger: context.logger)
    }
}

// MARK: - Mistral Proxy
// Synthesis + SSE parsing live in `MistralTTS` (shared with the realtime
// route); this handler only shapes the HTTP response: 8-byte format header
// followed by raw PCM.

private func proxySpeakToMistral(speakReq: SpeakRequest, logger: Logger) async throws -> Response {
    var headers = HTTPFields()
    headers[.contentType] = "audio/pcm"
    headers[.cacheControl] = "no-cache"

    #if canImport(FoundationNetworking)
    // Linux — FoundationNetworking has no URLSession.bytes; buffer the full response.
    let pcmData: Data
    do {
        pcmData = try await MistralTTS.buffered(
            text: speakReq.input,
            voiceID: speakReq.voiceId,
            model: speakReq.model,
            logger: logger
        )
    } catch is MistralTTS.TTSError {
        throw HTTPError(.badGateway, message: "Mistral TTS error.")
    }
    let responseData = makePCMResponse(pcmData, sampleRate: 24_000)
    return Response(
        status: .ok,
        headers: headers,
        body: .init(byteBuffer: ByteBuffer(bytes: responseData))
    )

    #else
    // Darwin — stream bytes from Mistral as they arrive using AsyncThrowingStream.
    let pcmStream: AsyncThrowingStream<Data, Error>
    do {
        pcmStream = try await MistralTTS.stream(
            text: speakReq.input,
            voiceID: speakReq.voiceId,
            model: speakReq.model,
            logger: logger
        )
    } catch is MistralTTS.TTSError {
        throw HTTPError(.badGateway, message: "Mistral TTS error.")
    }

    let (stream, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()

    Task {
        do {
            // Write the 8-byte format header first so iOS knows the sample rate.
            let header = makeFormatHeader(sampleRate: 24_000, bits: 32)
            continuation.yield(ByteBuffer(bytes: header))

            for try await pcmChunk in pcmStream {
                continuation.yield(ByteBuffer(bytes: pcmChunk))
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
            logger.error("[Speak] TTS stream error: \(error)")
        }
    }

    return Response(status: .ok, headers: headers, body: .init(asyncSequence: stream))
    #endif
}

// MARK: - Helpers

func makeFormatHeader(sampleRate: UInt32, channels: UInt16 = 1, bits: UInt16 = 16) -> Data {
    var h = Data(count: 8)
    h.withUnsafeMutableBytes { ptr in
        ptr.storeBytes(of: sampleRate.littleEndian, toByteOffset: 0, as: UInt32.self)
        ptr.storeBytes(of: channels.littleEndian,   toByteOffset: 4, as: UInt16.self)
        ptr.storeBytes(of: bits.littleEndian,       toByteOffset: 6, as: UInt16.self)
    }
    return h
}

private func makePCMResponse(_ pcm: Data, sampleRate: UInt32) -> Data {
    var out = makeFormatHeader(sampleRate: sampleRate, bits: 32)
    out.append(pcm)
    return out
}
