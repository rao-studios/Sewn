//
//  Seer.USer.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 12/15/25.
//



extension Seer {
    struct User: Codable {
        var groups: [Seer.Group]
    }
}
