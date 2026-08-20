//
//  RefreshRequest.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 2/22/26.
//



struct RefreshRequest: Codable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}
