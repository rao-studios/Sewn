// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "seer-server",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-argument-parser.git", .upToNextMajor(from: "1.3.0")),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
    .package(url: "https://github.com/realm/SwiftLint.git", .upToNextMajor(from: "0.59.1")),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.2.0"),
    .package(url: "https://github.com/Boilertalk/Web3.swift.git", from: "0.6.0"),
    .package(url: "https://github.com/apple/swift-container-plugin.git", from: "1.1.2"),
    .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.41.1"),
    .package(url: "https://github.com/swift-server/swift-prometheus.git", from: "2.0.0"),
    .package(url: "https://github.com/grpc/grpc-swift.git", from: "2.0.0"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "1.0.0"),
    .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    .package(path: "../../../rao/repositories/Conduit"),
    // .package(url: "https://github.com/rao-studios/Conduit.git", branch: "main")
  ],
  targets: [
    .executableTarget(
      name: "seer-server",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "Web3", package: "Web3.swift"),
        .product(name: "Web3PromiseKit", package: "Web3.swift"),
        .product(name: "Web3ContractABI", package: "Web3.swift"),
        .product(name: "Supabase", package: "supabase-swift"),
        .product(name: "Prometheus", package: "swift-prometheus"),
        .product(name: "GRPCCore", package: "grpc-swift"),
        .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
        .product(name: "Conduit", package: "Conduit"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]/*,
      plugins: [
          .plugin(name: "ContainerImageBuilder", package: "swift-container-plugin"),
      ]*/
    ),
    .testTarget(
      name: "seer-serverTests",
      dependencies: [
        "seer-server",
        .product(name: "HummingbirdTesting", package: "hummingbird"),
        .product(name: "HummingbirdWSTesting", package: "hummingbird-websocket"),
      ]
    )
  ]
)
