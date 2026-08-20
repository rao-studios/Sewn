//
//  Stats.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 5/12/26.
//

import Foundation
import Hummingbird
import HTTPTypes

struct StatsResponse: Codable {
    let publicDocumentCount: Int
    let publicGroupCount: Int
}

private actor StatsRateLimiter {
    private struct Window {
        var count: Int
        var windowStart: Date
    }

    private var windows: [String: Window] = [:]
    private let limit: Int
    private let windowSeconds: TimeInterval

    init(limit: Int = 10, windowSeconds: TimeInterval = 60) {
        self.limit = limit
        self.windowSeconds = windowSeconds
    }

    func allow(ip: String) -> Bool {
        let now = Date()
        if let existing = windows[ip], now.timeIntervalSince(existing.windowStart) < windowSeconds {
            if existing.count >= limit { return false }
            windows[ip]!.count += 1
        } else {
            windows[ip] = Window(count: 1, windowStart: now)
        }
        return true
    }
}

func registerStatsRoute(_ router: some RouterMethods<SeerRequestContext>, _ seer: Seer) {
    let limiter = StatsRateLimiter()

    router.get("/v1/stats") { request, context async throws -> StatsResponse in
        let ip = request.headers[HTTPField.Name("X-Forwarded-For")!]?
            .split(separator: ",").first
            .map { String($0).trimmingCharacters(in: CharacterSet.whitespaces) }
            ?? context.remoteAddress?.ipAddress
            ?? "unknown"

        guard await limiter.allow(ip: ip) else {
            throw HTTPError(.tooManyRequests)
        }

        let (groups, _, _) = await seer.fanoutLibrary(ownerId: "")
        let publicGroups = groups.filter { $0.access == .available }
        let groupCount    = publicGroups.count
        let documentCount = publicGroups.reduce(0) { $0 + $1.documents.count }
        return StatsResponse(publicDocumentCount: documentCount, publicGroupCount: groupCount)
    }
}
