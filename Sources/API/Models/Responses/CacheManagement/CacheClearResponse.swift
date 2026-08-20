//
//  CacheClearResponse.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 10/26/25.
//  Based on: https://github.com/mzbac/swift-mlx-server


import Foundation

/// Response model for cache clear operation
struct CacheClearResponse: Codable {
    let success: Bool
    let message: String
}
