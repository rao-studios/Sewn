//
//  MLXServerError.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 10/26/25.
//  Based on: https://github.com/mzbac/swift-mlx-server

import Foundation
import Logging
import Hummingbird
import NIOCore

protocol MLXServerError: HTTPResponseError {
    var modelId: String? { get }
    var underlyingError: Error? { get }
    var baseReason: String { get }

    init(status: HTTPResponse.Status, reason: String, modelId: String?, underlyingError: Error?)
}

extension MLXServerError {
    init(
        status: HTTPResponse.Status, reason: String, modelId: String? = nil,
        underlyingError: Error? = nil
    ) {
        self.init(
            status: status, reason: reason, modelId: modelId, underlyingError: underlyingError)
    }

    var errorBody: String {
        var fullReason = self.baseReason
        if let modelId = modelId, !modelId.isEmpty {
            fullReason += " (Model: \(modelId))"
        }
        if let underlyingError = underlyingError {
            fullReason += ". Underlying error: \(underlyingError.localizedDescription)"
        }
        return fullReason
    }

    func response(from request: Request, context: some RequestContext) throws -> Response {
        let message = self.errorBody
        // Escape quotes for JSON safety
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        let json = "{\"error\":{\"message\":\"\(escaped)\"}}"
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(
            status: self.status,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(string: json))
        )
    }
}
