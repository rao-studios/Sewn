// swift-tools-version: 6.0
// SewnClient — mission control for the Sewn network: start/manage Sewn and
// Thread servers, inspect and edit the knowledge graph, chat with cited
// sources, and run the ThinkingMachines (Tinker) research lab.
//
// Standalone SwiftPM executable (mirrors Fleet/Client). Talks to the servers
// over HTTP/SSE only — no in-process ML.

import PackageDescription

let package = Package(
    name: "SewnClient",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "SewnClient",
            path: "Sources",
            resources: [.copy("Resources/python")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
