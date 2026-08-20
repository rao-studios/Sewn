//
//  Seer.Request.swift
//  seer-server
//
//  Created by Ritesh Pakala on 11/8/25.
//

import Foundation
import Hummingbird

/// A payload in most endpoint requests to manage the requestor's
/// identity when making any request.
struct SeerRequest: Codable {
    // The owner/user id of the request.
    let ownerId: String
    // The groupId of documents or media that relates to the request.
    let group: Seer.Group?
    // Multi-group filter for chat completions. When non-nil and non-empty, HNSW search
    // is restricted to documents belonging to any of these groups.
    // Takes priority over `group` when both are provided.
    let groups: [Seer.Group]?
    /// Query entity terms for knowledge-graph matching on the Totem side.
    /// `tags` is kept as a legacy alias; consumers read `entities ?? tags`.
    let entities: [String]?
    // Search Predicate via tags attached to groups (legacy alias for entities).
    let tags: [String]?
    // aggregate == true  → search all of the owner's documents (across all groups).
    // aggregate == false → search only the group provided, or fall back to all owner docs.
    let aggregate: Bool?
    // .global   → search the entire network (access filter limits to .available docs).
    // .personal → search within the owner's content only (default when nil).
    let scope: SeerRequestScope?
    /// Totem node UUIDs (string form) that the client wants to target for this request.
    /// Populated from `totem_id` fields returned in search/chat `references`.
    /// Used by HNSW routes (targeted proxy) and remove operations (targeted fanout).
    let totemIds: [String]?
    /// The single totem UUID designated for personal storage operations (automemory,
    /// resonance). Unlike `totemIds` — which controls search fanout — this field is
    /// only consumed by server-side storage writes and does not restrict search.
    let personalTotemId: String?

    let requestID: String?

    init(ownerId: String,
         group: Seer.Group? = nil,
         groups: [Seer.Group]? = nil,
         entities: [String]? = nil,
         tags: [String]? = nil,
         aggregate: Bool? = nil,
         scope: SeerRequestScope? = nil,
         totemIds: [String]? = nil,
         personalTotemId: String? = nil,
         requestID: String? = nil) {
        self.ownerId = ownerId
        self.group = group
        self.groups = groups
        self.entities = entities
        self.tags = tags
        self.aggregate = aggregate
        self.scope = scope
        self.totemIds = totemIds
        self.personalTotemId = personalTotemId
        self.requestID = requestID
    }

    enum CodingKeys: String, CodingKey {
        case ownerId = "owner_id"
        case group
        case groups
        case entities
        case tags
        case aggregate
        case scope
        case totemIds       = "totem_ids"
        case personalTotemId = "personal_totem_id"
        case requestID      = "request_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ownerId          = try c.decode(String.self,                    forKey: .ownerId)
        group            = try c.decodeIfPresent(Seer.Group.self,       forKey: .group)
        groups           = try c.decodeIfPresent([Seer.Group].self,     forKey: .groups)
        entities         = try c.decodeIfPresent([String].self,         forKey: .entities)
        tags             = try c.decodeIfPresent([String].self,         forKey: .tags)
        aggregate        = try c.decodeIfPresent(Bool.self,             forKey: .aggregate)
        scope            = try c.decodeIfPresent(SeerRequestScope.self, forKey: .scope)
        totemIds         = try c.decodeIfPresent([String].self,         forKey: .totemIds)
        personalTotemId  = try c.decodeIfPresent(String.self,           forKey: .personalTotemId)
        requestID        = try c.decodeIfPresent(String.self,           forKey: .requestID)
    }

    func from(_ context: SeerRequestContext) throws -> SeerRequest {
        guard let userId = context.authUserId else {
            throw HTTPError(.internalServerError, message: "Authenticated user ID missing — route must be behind AuthMiddleware")
        }
        // Normalize to lowercase so registry key lookups are always consistent.
        // UUID.uuidString returns uppercase on all Swift platforms, but Supabase
        // auth.uid() is always lowercase — without this, ownership checks would
        // fail silently for any user whose ID was first registered via Supabase.
        return .init(
            ownerId: userId.lowercased(),
            group: self.group,
            groups: self.groups,
            entities: self.entities,
            tags: self.tags,
            aggregate: self.aggregate,
            scope: self.scope,
            totemIds: self.totemIds,
            personalTotemId: self.personalTotemId,
            requestID: context.id
        )
    }
}

enum SeerRequestScope: String, Codable {
    case global
    case personal
}
