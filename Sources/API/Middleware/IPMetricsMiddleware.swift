import Foundation
//
//  IPMetricsMiddleware.swift
//  sewn-server
//

import Metrics
import Hummingbird
import HTTPTypes

/// Global middleware that records one `sewn.http.requests_total` counter increment
/// for every HTTP request, labelled by route path, full client IP, deployment
/// region, and country code.
///
/// **Labels**
/// - `route`        — raw URI path of the request (Hummingbird does not expose
///                    the matched route template from middleware; raw path is used).
/// - `ip`           — client IP resolved in priority order:
///                    `X-Forwarded-For` first header (set by reverse proxies / Docker),
///                    then `X-Real-IP`, then `remoteAddress`. Strips port if present.
/// - `region`       — value of the `SEWN_REGION` environment variable, or `"unknown"`.
/// - `country_code` — resolved in priority order from CDN-injected headers:
///                    `CF-IPCountry` (Cloudflare), `CloudFront-Viewer-Country` (AWS),
///                    `X-Country-Code` (generic proxy). Falls back to `"unknown"`.
struct IPMetricsMiddleware: RouterMiddleware {
    typealias Context = SewnRequestContext

    private static let region: String =
        ProcessInfo.processInfo.environment["SEWN_REGION"] ?? "unknown"

    /// Paths that are polled by infrastructure (Alloy scrapes, load-balancer health
    /// checks) and must not inflate the business-traffic counter.
    private static let excludedPrefixes: [String] = ["/metrics", "/health"]

    func handle(
        _ request: Request,
        context: SewnRequestContext,
        next: (Request, SewnRequestContext) async throws -> Response
    ) async throws -> Response {
        let response = try await next(request, context)

        let path = request.uri.path
        guard !Self.excludedPrefixes.contains(where: { path.hasPrefix($0) }) else {
            return response
        }

        // X-Forwarded-For may contain a comma-separated chain; the first entry is the client.
        let ip: String
        if let forwarded = request.headers[HTTPField.Name("X-Forwarded-For")!] {
            ip = forwarded.split(separator: ",").first
                .map { String($0).trimmingCharacters(in: CharacterSet.whitespaces) } ?? "unknown"
        } else if let realIP = request.headers[HTTPField.Name("X-Real-IP")!] {
            ip = realIP
        } else {
            ip = context.remoteAddress?.ipAddress ?? "unknown"
        }

        let countryCode =
            request.headers[HTTPField.Name("CF-IPCountry")!] ??
            request.headers[HTTPField.Name("CloudFront-Viewer-Country")!] ??
            request.headers[HTTPField.Name("X-Country-Code")!] ??
            "unknown"

        Counter(
            label: "sewn.http.requests_total",
            dimensions: [
                ("route",        path),
                ("ip",           ip),
                ("region",       Self.region),
                ("country_code", countryCode),
            ]
        ).increment()

        return response
    }
}
