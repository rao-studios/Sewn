//
//  UpdatePasswordRequest.swift
//  sewn-server
//

/// The signed-in user's new password; the Bearer header says whose.
struct UpdatePasswordRequest: Codable {
    let password: String
}
