//
//  ResendRequest.swift
//  sewn-server
//

/// `type`: `signup` (the confirmation code) or `recovery` (a reset code).
struct ResendRequest: Codable {
    let email: String
    let type: String
}
