//
//  GroupListRequest.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 12/10/25.
//

import Foundation


struct GroupListRequest: Codable {
    let sewn: SewnRequest
    let limit: Int?
    let afterId: String?

    enum CodingKeys: String, CodingKey {
        case sewn
        case limit
        case afterId = "after_id"
    }
}
