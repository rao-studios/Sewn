import Foundation


struct GroupsByDocumentsRequest: Codable {
    let sewn: SewnRequest
    let documentIds: [DocumentID]

    enum CodingKeys: String, CodingKey {
        case sewn
        case documentIds = "document_ids"
    }
}
