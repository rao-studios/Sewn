import Conduit
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import RaoStack

actor SewnGRPCServer {
    private var serverTask: Task<Void, Error>?

    @discardableResult
    /// Binds where the HTTP server binds (`--host`): loopback for a Sewn an app
    /// launched for itself, 0.0.0.0 only where a deployment asks for it.
    /// `stack` decides who may register: anyone (open), the one app's Thread
    /// (single), or each app's Thread on a shared stack — where the secret it
    /// registers with records which app the node belongs to.
    func start(registry: RegistryMutator, nodeId: UUID, host: String, grpcPort: Int, stack: StackMode, sessionManager: ThreadSessionManager, logger: SewnLogger) -> ThreadSessionManager {
        let service = ThreadRegistrationServiceImpl(
            registry: registry,
            mothershipId: nodeId,
            sessionManager: sessionManager,
            logger: SewnConduitLogger(base: logger),
            callerResolver: stack.grpcResolver
        )
        // A shared stack takes any app's secret and names the app; one app's
        // stack takes its one secret; hosted (open): nothing is installed.
        let interceptors = stack.grpcResolver.map {
            StackSecretServerInterceptor.forLocalMode(resolver: $0, logger: SewnConduitLogger(base: logger))
        } ?? StackSecretServerInterceptor.forLocalMode(
            secret: stack.singleSecret, logger: SewnConduitLogger(base: logger))
        serverTask = Task {
            let server = GRPCServer(
                transport: .http2NIOPosix(
                    address: .ipv4(host: host, port: grpcPort),
                    transportSecurity: .plaintext,
                    config: .defaults {
                        $0.rpc.maxRequestPayloadSize = 100 * 1024 * 1024
                        // The big payloads (index/search/library responses, up
                        // to the cap above) arrive client→server on the bidi
                        // session stream — and the server's DEFAULT receive
                        // window is 64 KiB, capping throughput at ~window/RTT.
                        // That default was the congestion-like throttling on
                        // every large push. Open the window, fatten frames,
                        // accept gzip from nodes (payloads are text-heavy).
                        $0.http2.targetWindowSize = 16 * 1024 * 1024
                        $0.http2.maxFrameSize = 1 << 20
                        $0.compression.enabledAlgorithms = [.gzip, .none]
                        // Detect dead Thread connections from this side too
                        // (mirrors ConduitMothershipServer; previously the
                        // wired server had NO keepalive and relied entirely on
                        // the node's client-side pings + 45 s watchdog).
                        $0.connection.keepalive.time = .seconds(15)
                        $0.connection.keepalive.timeout = .seconds(10)
                        $0.connection.keepalive.clientBehavior.allowWithoutCalls = true
                        $0.connection.keepalive.clientBehavior.minPingIntervalWithoutCalls = .seconds(10)
                    }
                ),
                services: [service],
                // Local mode: the stack's secrets gate Register, Heartbeat,
                // UpdateAvailability and Session, as StackSecretMiddleware
                // does for HTTP.
                interceptors: interceptors
            )
            logger.info("SewnGRPCServer", "gRPC server listening on \(host):\(grpcPort)", service: .startup)
            do {
                try await server.serve()
            } catch is CancellationError {
                // stop() — a shutdown, not a failure.
            } catch {
                // Most often the port is taken. Dying loudly beats serving
                // HTTP with no mothership: the launcher sees the exit, and a
                // Thread never registers with whatever holds this port.
                logger.error("SewnGRPCServer", "gRPC server on \(host):\(grpcPort) failed: \(error)", service: .startup)
                exit(EXIT_FAILURE)
            }
        }
        return sessionManager
    }

    func stop() {
        serverTask?.cancel()
        serverTask = nil
    }
}
