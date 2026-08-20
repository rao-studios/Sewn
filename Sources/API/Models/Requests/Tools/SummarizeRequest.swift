//
//  SummarizeRequest.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/1/25.
//



struct SummarizeRequest: Codable {
    let content: String
    let seer: SeerRequest
}
