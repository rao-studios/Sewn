//
//  Embedding.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/1/25.
//

import Foundation

struct Embedding: Codable {
    let embedding: [Float]
    let text: [String]
}
