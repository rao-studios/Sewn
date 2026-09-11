//
//  LocalGPU.swift
//  Sewn
//
//  WHAT: Whether MLX can reach the GPU (`mlx.metallib` where MLX looks).
//  OUT:  reachable / honest miss, for GET /v1/providers
//  PIN:  File check, not "try it" — MLX's failure to find its library is an
//        uncatchable C++ abort, so this must never touch an MLX symbol.
//

import Foundation

enum LocalGPU {

    struct Candidate: Sendable, Equatable {
        let rung: String
        let path: String
        let exists: Bool
    }

    struct Report: Sendable, Equatable {
        var isSatisfied: Bool { found != nil }
        let found: Candidate?
        let searched: [Candidate]
    }

    /// The directory holding the running executable — MLX's first rung.
    static var binaryDirectory: URL {
        URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
    }

    /// Read the search path. Touches no MLX symbol and cannot fail.
    static func report(binaryDirectory: URL = LocalGPU.binaryDirectory) -> Report {
        let rungs: [(String, URL)] = [
            ("colocated mlx.metallib", binaryDirectory
                .appendingPathComponent("mlx.metallib")),
            ("colocated Resources/mlx.metallib", binaryDirectory
                .appendingPathComponent("Resources/mlx.metallib")),
            ("colocated Resources/default.metallib", binaryDirectory
                .appendingPathComponent("Resources/default.metallib")),
            // METAL_PATH, the compile-time constant: a RELATIVE path, so it
            // resolves against the working directory rather than the binary.
            ("METAL_PATH (relative to cwd)", URL(
                fileURLWithPath: "default.metallib",
                relativeTo: URL(fileURLWithPath: FileManager.default
                    .currentDirectoryPath))),
        ]
        let searched = rungs.map { rung, url in
            Candidate(
                rung: rung,
                path: url.standardizedFileURL.path,
                exists: FileManager.default.fileExists(
                    atPath: url.standardizedFileURL.path))
        }
        return Report(found: searched.first(where: \.exists), searched: searched)
    }

    /// What to tell a person when the GPU cannot start.
    static func remedy() -> String {
        """
        No MLX Metal library found beside sewn-server. Run \
        ./scripts/build-metallib.sh release, which compiles Frigate's vendored \
        shaders into .build/release/mlx.metallib — `swift build` cannot do it, \
        because SwiftPM has no Metal step.
        """
    }
}
