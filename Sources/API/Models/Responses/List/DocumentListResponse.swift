//
//  DocumentListResponse.swift
//  sewn-server
//
//  Created by Ritesh Pakala on 11/13/25.
//

import Foundation


struct DocumentListResponse: Codable {
    var object: String = "list"
    let documents: [Sewn.Document]
    let access: [DocumentID : SewnRegistry.Access]
}
