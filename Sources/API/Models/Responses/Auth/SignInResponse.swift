//
//  SignInResponse.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 2/22/26.
//



struct SignInResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Double
    let userId: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case userId = "user_id"
    }
}
