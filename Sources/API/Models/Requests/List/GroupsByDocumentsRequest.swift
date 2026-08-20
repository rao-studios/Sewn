import Foundation


struct GroupsByDocumentsRequest: Codable {
    let seer: SeerRequest
    let documentIds: [DocumentID]

    enum CodingKeys: String, CodingKey {
        case seer
        case documentIds = "document_ids"
    }
}
