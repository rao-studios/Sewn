//
//  LoggerRequests.swift
//  Seer
//
//  Created by Ritesh Pakala on 2/15/26.
//

import Foundation

extension Requests {
    struct Logger {}
}

extension Requests.Logger {
    struct CreateAirtable: NetworkRequest {
        typealias Response = Result

        var path: String { "v0/appcZ2otltC4PMzGG/tbli7ZitN9VQ3rz4p" }
        var method: RequestMethod { .post }

        let records: [Record]

        struct Record: Codable {
            let fields: Fields
        }

        struct Fields: Codable {
            let eventName: String
            let eventMetadata: String
            let eventType: String
            let userID: String
            let services: String
            let requestID: String?

            enum CodingKeys: String, CodingKey {
                case eventName = "Event Name"
                case eventMetadata = "Event Metadata"
                case eventType = "Event Type"
                case userID = "User ID"
                case services = "Services"
                case requestID = "Request ID"
            }
        }

        init(
            eventName: String,
            eventMetadata: String,
            eventType: String,
            userID: String,
            services: SeerLogger.ServicesType,
            requestID: String? = nil
        ) {
            self.records = [
                Record(
                    fields: Fields(
                        eventName: eventName,
                        eventMetadata: eventMetadata,
                        eventType: eventType,
                        userID: userID,
                        services: services.rawValue.capitalized,
                        requestID: requestID
                    )
                )
            ]
        }

        // MARK: Response Model

        struct Result: Codable {
            let records: [ResponseRecord]
        }

        struct ResponseRecord: Codable {
            let id: String
            let createdTime: String
            let fields: ResponseFields
        }

        struct ResponseFields: Codable {
            let eventName: String
            let eventType: String
            let occurredAt: String
            let userID: String
            let eventMetadataSummary: ComputedField?
            let eventRootCauseAnalysis: ComputedField?

            enum CodingKeys: String, CodingKey {
                case eventName = "Event Name"
                case eventType = "Event Type"
                case occurredAt = "Occurred At"
                case userID = "User ID"
                case eventMetadataSummary = "Event Metadata Summary"
                case eventRootCauseAnalysis = "Event Root Cause Analysis"
            }
        }

        struct ComputedField: Codable {
            let state: String
            let errorType: String?
            let value: String?
            let isStale: Bool
        }
    }

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
            services: SeerLogger.ServicesType,
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
