import Foundation


struct GroupsByDocumentsResponse: Codable {
    var object: String = "list"
    /// Unique groups referenced by the requested documents.
    let groups: [Seer.Group]
    /// Maps each requested document ID to its group ID (omitted when ungrouped).
    let documentGroups: [DocumentID: GroupID]
    let access: [GroupID: SeerRegistry.Access]

    enum CodingKeys: String, CodingKey {
        case object
        case groups
        case documentGroups = "document_groups"
        case access
    }
}
