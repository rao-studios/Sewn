//
//  Sewn.Wearable.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/2/25.
//

import Foundation

/* Endgame: The World Computer. */

/// Wearable data that is placed into Sewn's database network.
/// Stored in embedding form, leading to contextual insights around
/// queries based on real-life environment variables.
extension Sewn {
    struct Wearable: Codable {
        var url: URL
        var embedding: [Float]
        var kind: Kind
        
        enum Kind: String, Codable {
            case pin
            case ring
            case belt
            case bracelet
            case necklace
            case earring
            case glasses
        }
    }
}

/*
 Challenge:
 - Streaming encrypted embeddings into the right buckets continously. Nonstop.
 - Realtime knowledge and self-awareness. Without cameras.
 */
