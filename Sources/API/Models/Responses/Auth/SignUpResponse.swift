//
//  SignUpResponse.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 2/22/26.
//

import Supabase


/// Returned by sign-up and verify (OTP confirmation). When Supabase requires
/// email confirmation, only `userId` / `email` are populated and
/// `requiresConfirmation` is `true`. Once confirmed a full session is returned.
struct SignUpResponse: Codable {
    let userId: String
    let email: String?
    let requiresConfirmation: Bool
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Double?
    let expiresAt: Double?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case email
        case requiresConfirmation = "requires_confirmation"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
    }

    init(from authResponse: AuthResponse) {
        switch authResponse {
        case .session(let session):
            userId = session.user.id.uuidString
            email = session.user.email
            requiresConfirmation = false
            accessToken = session.accessToken
            refreshToken = session.refreshToken
            expiresIn = session.expiresIn
            expiresAt = session.expiresAt
        case .user(let user):
            userId = user.id.uuidString
            email = user.email
            requiresConfirmation = true
            accessToken = nil
            refreshToken = nil
            expiresIn = nil
            expiresAt = nil
        }
    }
}
