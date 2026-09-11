//
//  ModelProviderError.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 10/26/25.
//  Based on: https://github.com/mzbac/swift-mlx-server

import Foundation
import Logging
import Hummingbird

struct ModelProviderError: MLXServerError {
    let status: HTTPResponse.Status
    let baseReason: String
    let identifier: String?
    let modelId: String?
    let underlyingError: Error?

    init(
        status: HTTPResponse.Status, reason: String, modelId: String? = nil,
        underlyingError: Error? = nil
    ) {
        self.status = status
        self.baseReason = reason
        self.identifier = modelId
        self.modelId = modelId
        self.underlyingError = underlyingError
    }
}
