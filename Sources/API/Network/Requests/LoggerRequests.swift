//
//  LoggerRequests.swift
//  Sewn
//
//  Created by Ritesh Pakala on 2/15/26.
//

import Foundation

extension Requests {
    struct Logger {}
}

extension Requests.Logger {
    struct Create: NetworkRequest {
        typealias Response = EmptyResponse

        var path: String { "rest/v1/logs" }
        var method: RequestMethod { .post }

        let eventName: String
        let eventMetadata: String
        let eventType: String
        // let occurredAt: String
        let userID: String
        let services: String
        let requestID: String?
        let id: String

        enum CodingKeys: String, CodingKey {
            case eventName = "Event Name"
            case eventMetadata = "Event Metadata"
            case eventType = "Event Type"
            // case occurredAt = "Occurred At"
            case userID = "User ID"
            case services = "Services"
            case requestID = "Request ID"
            case id
        }

        init(
            eventName: String,
            eventMetadata: String,
            eventType: String,
            userID: String,
            services: SewnLogger.ServicesType,
            requestID: String? = nil
        ) {
            self.eventName = eventName
            self.eventMetadata = eventMetadata
            self.eventType = eventType
            // Letting supabase create a timestamp at log creation time to ensure consistency and avoid client clock issues.
            // self.occurredAt = ISO8601DateFormatter().string(from: Date())
            self.userID = userID
            self.services = services.rawValue.capitalized
            self.requestID = requestID
            self.id = UUID().uuidString
        }
    }
}
