import ArgumentParser
import Conduit
import Foundation
import Logging
import Metrics
import Prometheus
import Hummingbird
import HummingbirdWebSocket
import HTTPTypes

// MARK: - Route configuration

func configureRoutes(
    _ router: Router<SeerRequestContext>,
    _ seer: Seer,
    modelProvider: ModelProvider,
    isVLM: Bool
) {
    registerTotemNodesRoute(router, seer)

    // Open routes — no auth required.
    registerHealthRoute(router)
    registerMetricsRoute(router)
    registerStatsRoute(router, seer)
    registerAuthSignInRoute(router)
    registerAuthSignUpRoute(router, seer)
    registerAuthVerifyRoute(router, seer)
    registerAuthRefreshRoute(router)
    registerAuthResetPasswordRoute(router)

    // Protected routes — AuthMiddleware validates the Supabase Bearer token
    // and populates context.authUserId before each handler runs.
    let protected = router.add(middleware: AuthMiddleware())
    try? registerChatCompletionsRoute(
        protected,
        seer,
        modelProvider: modelProvider,
        isVLM: isVLM
    )
    registerVisionLookRoute(protected)
    registerProvidersRoutes(protected, modelProvider: modelProvider)
    registerCompleteRoute(protected, modelProvider: modelProvider)
    registerSkillsCompleteRoute(protected, modelProvider: modelProvider)
    registerCodeCompleteRoute(protected, modelProvider: modelProvider)
    registerEmbeddingsRoute(
        protected,
        seer,
        modelProvider: modelProvider
    )
    // Returns vectors rather than storing documents — see EmbedVectors.swift.
    registerEmbedVectorsRoute(protected)
    registerSearchRoute(
        protected,
        seer,
        modelProvider: modelProvider
    )
    registerModifyRoute(protected, seer)
    registerModifyGroupRoute(protected, seer)
    registerModifyGroupRemoveRoute(protected, seer)
    registerModifyGroupMetadataRoute(protected, seer)
    /* Tools */
    registerSummarizeRoute(
        protected,
        seer,
        modelProvider: modelProvider
    )
    /* List */
    registerListDocumentsRoute(protected, seer)
    registerListGroupsRoute(protected, seer)
    registerListGroupsByDocumentsRoute(protected, seer)
    /* Infinite — public group leaderboard and search */
    registerInfiniteRoutes(protected, seer)
    /* Auth — sign-out requires a live session */
    registerAuthSignOutRoute(protected)
    /* Graph — knowledge-graph query proxy (entity match + neighborhood) */
    registerGraphRoute(protected, seer)
    /* Personalities — chat personas */
    registerPersonalitiesRoute(protected, seer)
    /* Profile */
    registerProfileRoute(protected)
    registerUpdateProfileRoute(protected)
    /* Frank — GBT model inspect */
    registerFrankRoutes(protected, seer)
    /* Marielle — proactive personalization */
    registerMarielleRoutes(protected, seer, modelProvider: modelProvider)
    /* Speak — Mistral TTS proxy */
    registerSpeakRoute(protected)
    /* Forms — user feedback ingestion */
    registerFeedbackRoute(protected)
    /* Wallet — earnings summary and cashout history */
    registerWalletRoute(protected, seer)
    /* Admin — privileged cross-account operations, gated by AdminMiddleware */
    let admin = router.add(middleware: AdminMiddleware())
    registerAdminRoutes(admin, seer)
    registerAdminPersonalitiesRoute(admin, seer)
}

/// Builds the WebSocket router served through the HTTP1 upgrade channel.
/// Separate from the HTTP router so upgrade matching never scans routes that
/// can't upgrade; bearer auth happens in each route's `shouldUpgrade`.
func configureWebSocketRoutes(
    _ seer: Seer,
    modelProvider: ModelProvider
) -> Router<BasicWebSocketRequestContext> {
    let wsRouter = Router(context: BasicWebSocketRequestContext.self)
    registerRealtimeRoute(wsRouter, seer, modelProvider: modelProvider)
    return wsRouter
}

// MARK: - .env loader

func loadDotEnv(path: String = ".env") {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return }
    for line in contents.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let eq = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[..<eq])
        let value = String(trimmed[trimmed.index(after: eq)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        setenv(key, value, 1)
    }
}

// MARK: - Server & CLI

/// Main Server entry point.
@main
struct SeerServer: AsyncParsableCommand {
    @ArgumentParser.Option(name: .long, help: "Host address.")
    var host: String = AppConstants.defaultHost

    @ArgumentParser.Option(name: .long, help: "Port number.")
    var port: Int = AppConstants.defaultPort

    @ArgumentParser.Flag(name: .long, help: "Enable multi-modal processing for visual language models.")
    var vlm: Bool = false

    @ArgumentParser.Flag(name: .long, help: "Enable prompt caching to reuse KV caches for common prefixes.")
    var enablePromptCache: Bool = false

    @ArgumentParser.Option(name: .long, help: "Maximum prompt cache size in MB (default: 1024).")
    var promptCacheSizeMB: Int = 1_024

    @ArgumentParser.Option(name: .long, help: "Prompt cache TTL in minutes (default: 30).")
    var promptCacheTTLMinutes: Int = 30

    // @ArgumentParser.Flag(name: .long, help: "Enable Totem gRPC node registration and search fan-out.")
    var enableTotems: Bool = true

    @ArgumentParser.Option(name: .long, help: "gRPC port for Totem registration service (default 9090).")
    var grpcPort: Int = 9091

    enum CodingKeys: CodingKey {
        case host, port, vlm
        case enablePromptCache, promptCacheSizeMB, promptCacheTTLMinutes
        case enableTotems, grpcPort
    }

    @MainActor
    func run() async throws {
        // ── Load .env before anything reads environment variables ────────────
        loadDotEnv()

        // ── Logging ──────────────────────────────────────────────────────────
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .debug
            return handler
        }
        var logger = Logger(label: "seer")
        logger.logLevel = .debug

        // ── Metrics ──────────────────────────────────────────────────────────
        MetricsSystem.bootstrap(PrometheusMetricsFactory())

        // ── Core services ─────────────────────────────────────────────────────
        let seer = Seer()
        let modelProvider = ModelProvider(logger: logger)

        // ── Wire Totem gRPC ───────────────────────────────────────────────────
        if enableTotems {
            let sessionManager = TotemSessionManager(logger: SeerConduitLogger(base: SeerLogger(logger)))
            let grpcServer = SeerGRPCServer()
            seer._totemQueryClient = TotemQueryClient(sessionManager: sessionManager)
            await grpcServer.start(
                registry: seer.nonisolatedRegistryMutator,
                nodeId: seer.nodeId,
                grpcPort: grpcPort,
                sessionManager: sessionManager,
                logger: SeerLogger(logger)
            )
            SeerLogger(logger).info("Startup", "Totem gRPC enabled on port \(grpcPort)", service: .startup)
        }

        // ── Router + middleware ───────────────────────────────────────────────
        let router = Router(context: SeerRequestContext.self)
        router.middlewares.add(CORSMiddleware(
            allowOrigin: .all,
            allowHeaders: [.accept, .authorization, .contentType, .origin, .userAgent, HTTPField.Name("X-Requested-With")!],
            allowMethods: [.get, .post, .delete, .options]
        ))
        router.middlewares.add(IPMetricsMiddleware())

        // ── Register ALL routes before Application.init freezes the responder ─
        configureRoutes(router, seer, modelProvider: modelProvider, isVLM: vlm)
        let wsRouter = configureWebSocketRoutes(seer, modelProvider: modelProvider)

        // ── Build Application AFTER all routes are registered ─────────────────
        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
            configuration: .init(
                address: .hostname(host, port: port),
                serverName: "Seer"
            ),
            logger: logger
        )

        let seerLogger = SeerLogger(logger)
        seerLogger.info("Startup", "Server starting on http://\(host):\(port)", service: .startup)
        let provider = LLMProvider.serverDefault
        seerLogger.info(
            "Startup",
            "Default provider: \(provider.rawValue) (\(ModelConfig.chatModel(for: provider)))",
            service: .startup)
        if await modelProvider.local.isBuilt {
            let gpu = LocalGPU.report()
            seerLogger.info(
                "Startup",
                "On-device provider: \(gpu.isSatisfied ? "available" : "no Metal library — run scripts/build-metallib.sh")",
                service: .startup)
            // A server whose default IS local should not make the first turn
            // wait for a multi-gigabyte load.
            if provider.isLocal, gpu.isSatisfied {
                let local = modelProvider.local
                let modelID = ModelConfig.chatModel(for: .local)
                Task { await local.warm(modelID: modelID) }
            }
        } else {
            seerLogger.info(
                "Startup", "On-device provider: not built (MLX is macOS-only)", service: .startup)
        }
        seerLogger.info("Startup", "VLM mode: \(vlm ? "enabled" : "disabled")", service: .startup)
        seerLogger.info(
            "Startup",
            "Prompt cache: \(enablePromptCache ? "enabled (size: \(promptCacheSizeMB)MB, TTL: \(promptCacheTTLMinutes)min)" : "disabled")",
            service: .startup
        )

        do {
            try await app.runService()
        } catch {
            await seer.shutdown()
            throw error
        }
        await seer.shutdown()
    }
}
