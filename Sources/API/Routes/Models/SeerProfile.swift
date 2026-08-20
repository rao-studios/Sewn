import Foundation
import Hummingbird

struct SeerProfile: Codable {
    let userId: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
    }
}