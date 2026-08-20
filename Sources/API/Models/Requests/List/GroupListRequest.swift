//
//  GroupListRequest.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 12/10/25.
//

import Foundation


struct GroupListRequest: Codable {
    let seer: SeerRequest
    let limit: Int?
    let afterId: String?

    enum CodingKeys: String, CodingKey {
        case seer
        case limit
        case afterId = "after_id"
    }
}
