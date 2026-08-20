//
//  SearchRequest.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/1/25.
//



struct SearchRequest: Codable {
    let model: String?
    let query: String
    let train: Bool
    let seer: SeerRequest

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        query = try container.decode(String.self, forKey: .query)
        train = try container.decodeIfPresent(Bool.self, forKey: .train) ?? false
        seer = try container.decode(SeerRequest.self, forKey: .seer)
    }
}
