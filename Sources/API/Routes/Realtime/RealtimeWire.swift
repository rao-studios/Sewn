//
//  RealtimeWire.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 7/22/26.
//

import Foundation

// MARK: - Inbound (client → server)

/// The single client frame that starts a realtime turn. `request` is the
/// exact `ChatCompletionRequest` JSON the SSE route accepts — one Codable,
/// one wire shape, two transports.
struct RealtimeTurnStart: Decodable {
    let type: String
    let request: ChatCompletionRequest
    let tts: TTSOptions?

    struct TTSOptions: Decodable {
        let voiceId: String?
        let model: String?
        enum CodingKeys: String, CodingKey {
            case voiceId = "voice_id"
            case model
        }
    }
}

/// Minimal probe used to classify inbound frames after `turn.start`
/// (currently only `{"type":"cancel"}` is meaningful; close is equivalent).
struct RealtimeInboundProbe: Decodable {
    let type: String
}

// MARK: - Outbound (server → client)

enum RealtimePhase: String, Codable, Sendable {
    case opening
    case grounded
}

/// Frames the realtime turn emits. JSON text frames throughout, except PCM
/// audio which rides raw binary frames — ordering on the socket implies
/// audio sequence, and `audio.begin` announces the format once.
enum RealtimeOutbound: Sendable {
    case phase(RealtimePhase)
    case token(RealtimePhase, String)
    case audioBegin(sampleRate: UInt32, channels: UInt16, bits: UInt16)
    case pcm(Data)
    case ttsFailed
    /// Pre-encoded `ChatCompletionChunkResponse` JSON (empty choices,
    /// contribution + auto_memory) — the SSE trailing chunk, reused verbatim
    /// so clients decode it with their existing chunk Codable.
    case metadata(chunkJSON: Data)
    case turnEnd
    case error(stage: String, message: String)

    /// The frame as WebSocket payload: `.text` JSON or `.binary` PCM.
    enum Payload {
        case text(String)
        case binary(Data)
    }

    var payload: Payload {
        switch self {
        case .pcm(let data):
            return .binary(data)
        case .phase(let phase):
            return .text(Self.json(["type": "phase", "phase": phase.rawValue]))
        case .token(let phase, let text):
            return .text(Self.json(["type": "token", "phase": phase.rawValue, "text": text]))
        case .audioBegin(let rate, let channels, let bits):
            return .text(Self.json([
                "type": "audio.begin",
                "sample_rate": Int(rate),
                "channels": Int(channels),
                "bits": Int(bits),
                "encoding": "f32le",
            ]))
        case .ttsFailed:
            return .text(Self.json(["type": "tts.failed"]))
        case .metadata(let chunkJSON):
            let chunk = String(data: chunkJSON, encoding: .utf8) ?? "{}"
            return .text("{\"type\":\"metadata\",\"chunk\":\(chunk)}")
        case .turnEnd:
            return .text(Self.json(["type": "turn.end"]))
        case .error(let stage, let message):
            return .text(Self.json(["type": "error", "stage": stage, "message": message]))
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
