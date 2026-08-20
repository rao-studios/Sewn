//
//  MistralTTSStream.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 7/22/26.
//

import Foundation
import Logging

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reusable Mistral voxtral TTS client: text in, raw float32 LE 24 kHz mono
/// PCM deltas out. Extracted from the `/v1/speak` proxy so the realtime
/// WebSocket route can synthesize per-sentence without going through HTTP.
/// `/v1/speak` remains a thin caller — its wire format is unchanged.
enum MistralTTS {
    static let defaultModel = "voxtral-mini-tts-2603"
    static let sampleRate: UInt32 = 24_000

    enum TTSError: Error {
        case badStatus(Int)
    }

    // MARK: - Request

    static func makeRequest(text: String, voiceID: String, model: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.mistral.ai/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(NetworkService.BaseEndpoint.mistral.apiKey)",
            forHTTPHeaderField: "Authorization"
        )
        let body: [String: Any] = [
            "model":           model,
            "input":           text,
            "voice_id":        voiceID,
            "response_format": "pcm",
            "stream":          true,   // always stream from Mistral for lower latency
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Streaming (Darwin) / buffered (Linux fallback)

    #if !canImport(FoundationNetworking)
    /// Opens the Mistral TTS stream and yields decoded PCM deltas as they
    /// arrive. Throws before returning when the HTTP status is not 2xx.
    static func stream(
        text: String,
        voiceID: String,
        model: String = defaultModel,
        logger: Logger
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let request = try makeRequest(text: text, voiceID: voiceID, model: model)
        let (asyncBytes, urlResponse) = try await URLSession.shared.bytes(for: request)
        guard let http = urlResponse as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw TTSError.badStatus((urlResponse as? HTTPURLResponse)?.statusCode ?? -1)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let decoder = JSONDecoder()
                    var currentEvent: String? = nil
                    var lineCount = 0
                    for try await line in asyncBytes.lines {
                        lineCount += 1
                        if lineCount <= 6 {
                            logger.info("[Speak] Mistral SSE line \(lineCount): \(line.prefix(120))")
                        }
                        if line.isEmpty {
                            currentEvent = nil
                            continue
                        }
                        if line.hasPrefix("event:") {
                            currentEvent = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                            continue
                        }
                        if line.hasPrefix("data:") {
                            let dataStr = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if dataStr == "[DONE]" { break }
                            let isAudioEvent = currentEvent == "speech.audio.delta" || currentEvent == nil
                            guard let pcmChunk = extractPCM(from: dataStr, requireDelta: isAudioEvent, decoder: decoder)
                            else { continue }
                            continuation.yield(pcmChunk)
                            continue
                        }
                        // NDJSON fallback: line is a bare JSON object (no SSE prefix)
                        if let pcmChunk = parseDeltaLine(line, decoder: decoder) {
                            continuation.yield(pcmChunk)
                        }
                    }
                    logger.info("[Speak] Mistral SSE done — \(lineCount) lines total.")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                    logger.error("[Speak] TTS stream error: \(error)")
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    #endif

    /// Single-shot synthesis: the whole clip as one PCM buffer. The only path
    /// on Linux (FoundationNetworking has no `URLSession.bytes`).
    static func buffered(
        text: String,
        voiceID: String,
        model: String = defaultModel,
        logger: Logger
    ) async throws -> Data {
        let request = try makeRequest(text: text, voiceID: voiceID, model: model)
        let (data, urlResponse): (Data, URLResponse) = try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (data ?? Data(), response!))
            }.resume()
        }
        guard let http = urlResponse as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw TTSError.badStatus((urlResponse as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let lines = data.split(separator: UInt8(ascii: "\n")).compactMap {
            String(bytes: $0, encoding: .utf8)
        }
        return try collectPCMFromLines(lines, logger: logger)
    }

    // MARK: - SSE payload parsing

    /// One SSE event from Mistral's streaming TTS endpoint.
    struct AudioEvent: Decodable {
        let event: String
        let data:  AudioEventData
    }

    struct AudioEventData: Decodable {
        let audioData: String?
        enum CodingKeys: String, CodingKey {
            case audioData = "audio_data"
        }
    }

    static func extractPCM(from jsonStr: String, requireDelta: Bool, decoder: JSONDecoder) -> Data? {
        guard !jsonStr.isEmpty, jsonStr != "[DONE]",
              let jsonData = jsonStr.data(using: .utf8) else { return nil }

        if let dataObj = try? decoder.decode(AudioEventData.self, from: jsonData),
           let b64 = dataObj.audioData,
           let pcm = Data(base64Encoded: b64) {
            return pcm
        }

        if let event = try? decoder.decode(AudioEvent.self, from: jsonData) {
            guard !requireDelta || event.event == "speech.audio.delta" else { return nil }
            guard let b64 = event.data.audioData,
                  let pcm = Data(base64Encoded: b64) else { return nil }
            return pcm
        }

        return nil
    }

    static func parseDeltaLine(_ line: String, decoder: JSONDecoder) -> Data? {
        let jsonStr = line.hasPrefix("data: ") ? String(line.dropFirst(6)) : line
        guard !jsonStr.isEmpty, jsonStr != "[DONE]",
              let jsonData = jsonStr.data(using: .utf8),
              let event    = try? decoder.decode(AudioEvent.self, from: jsonData),
              event.event  == "speech.audio.delta",
              let b64      = event.data.audioData,
              let pcm      = Data(base64Encoded: b64)
        else { return nil }
        return pcm
    }

    static func collectPCMFromLines(_ lines: [String], logger: Logger) throws -> Data {
        let decoder = JSONDecoder()
        var result  = Data()
        var currentEvent: String? = nil
        for line in lines {
            if line.isEmpty { currentEvent = nil; continue }
            if line.hasPrefix("event:") {
                currentEvent = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                continue
            }
            let dataStr: String
            if line.hasPrefix("data:") {
                dataStr = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else {
                dataStr = line
            }
            if dataStr == "[DONE]" { break }
            let isAudioEvent = currentEvent == "speech.audio.delta" || currentEvent == nil
            if let chunk = extractPCM(from: dataStr, requireDelta: isAudioEvent, decoder: decoder) {
                result.append(chunk)
            }
        }
        logger.info("[Speak] TTS buffered — \(result.count) PCM bytes")
        return result
    }
}
