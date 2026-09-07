//
//  Sewn.USer.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 12/15/25.
//



extension Sewn {
    struct User: Codable {
        var groups: [Sewn.Group]
    }
}
