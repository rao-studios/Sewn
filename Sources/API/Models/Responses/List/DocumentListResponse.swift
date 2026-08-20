//
//  DocumentListResponse.swift
//  seer-server
//
//  Created by Ritesh Pakala on 11/13/25.
//

import Foundation


struct DocumentListResponse: Codable {
    var object: String = "list"
    let documents: [Seer.Document]
    let access: [DocumentID : SeerRegistry.Access]
}
