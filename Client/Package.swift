// swift-tools-version: 6.0
// SeerClient — mission control for the Seer network: start/manage Seer and
// Totem servers, inspect and edit the knowledge graph, chat with cited
// sources, and run the ThinkingMachines (Tinker) research lab.
//
// Standalone SwiftPM executable (mirrors Fleet/Client). Talks to the servers
// over HTTP/SSE only — no in-process ML.

import PackageDescription

let package = Package(
    name: "SeerClient",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "SeerClient",
            path: "Sources",
            resources: [.copy("Resources/python")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
