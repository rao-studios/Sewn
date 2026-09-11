//
//  VerifyRequest.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 2/22/26.
//



/// Verifies an email OTP sent by Supabase.
/// - `type`: one of `signup`, `invite`, `magiclink`, `recovery`,
///   `email_change`, `email`
struct VerifyRequest: Codable {
    let email: String
    let token: String
    let type: String

    enum CodingKeys: String, CodingKey {
        case email
        case token
        case type
    }
}
