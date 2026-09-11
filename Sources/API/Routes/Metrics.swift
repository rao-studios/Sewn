//
//  Metrics.swift
//  sewn-server
//

import Foundation
import Prometheus
import Hummingbird
import NIOCore

func registerMetricsRoute(_ router: some RouterMethods<SewnRequestContext>) {
    router.get("/metrics") { request, context async throws -> Response in
        if let token = ProcessInfo.processInfo.environment["METRICS_TOKEN"], !token.isEmpty {
            guard let authHeader = request.headers[.authorization],
                  authHeader.hasPrefix("Bearer "),
                  String(authHeader.dropFirst(7)) == token else {
                throw HTTPError(.unauthorized)
            }
        }
        let body = PrometheusMetricsFactory.defaultRegistry.emitToString()
        var headers = HTTPFields()
        headers[.contentType] = "text/plain; version=0.0.4"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(string: body)))
    }
}
