//
//  MarielleOpenRequest.swift
//  Sewn
//
//  Created by Ritesh Pakala on 3/25/26.
//



/// Request for `POST /v1/marielle/open`.
/// Marielle examines the requestor's personal HNSW and generates a single
/// opening/ice-breaker question based on recency-weighted document candidates.
struct MarielleOpenRequest: Codable {
    let sewn: SewnRequest
}
