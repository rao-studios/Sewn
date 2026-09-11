//
//  CacheStatusResponse.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 10/26/25.
//  Based on: https://github.com/mzbac/swift-mlx-server


import Foundation

/// Response model for cache status
struct CacheStatusResponse: Codable {
    let enabled: Bool
    let entryCount: Int
    let currentSizeMB: Double
    let maxSizeMB: Int
    let ttlMinutes: Int
    let stats: CacheStatsResponse
}
