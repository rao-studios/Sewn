import Foundation
import Hummingbird

struct SewnProfile: Codable {
    let userId: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
    }
}