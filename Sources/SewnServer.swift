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
    _ router: Router<SewnRequestContext>,
    _ sewn: Sewn,
    modelProvider: ModelProvider,
    isVLM: Bool,
    serverMode: Bool
) {
    registerThreadNodesRoute(router, sewn)

    // Open routes — no auth required.
    registerHealthRoute(router)
    // Only a hosted server is scraped (Alloy → Cockpit). A Sewn launched for
    // one Mac has no scraper and no METRICS_TOKEN to guard the route with.
    if serverMode {
        registerMetricsRoute(router)
    }
    registerStatsRoute(router, sewn)
    registerAuthSignInRoute(router)
    registerAuthSignUpRoute(router, sewn)
    registerAuthVerifyRoute(router, sewn)
    registerAuthRefreshRoute(router)
    registerAuthResetPasswordRoute(router)
    registerAuthResendRoute(router)

    // Protected routes — AuthMiddleware validates the Supabase Bearer token
    // and populates context.authUserId before each handler runs.
    let protected = router.add(middleware: AuthMiddleware())
    try? registerChatCompletionsRoute(
        protected,
        sewn,
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
        sewn,
        modelProvider: modelProvider
    )
    // Returns vectors rather than storing documents — see EmbedVectors.swift.
    registerEmbedVectorsRoute(protected)
    registerSearchRoute(
        protected,
        sewn,
        modelProvider: modelProvider
    )
    registerModifyRoute(protected, sewn)
    registerModifyGroupRoute(protected, sewn)
    registerModifyGroupRemoveRoute(protected, sewn)
    registerModifyGroupMetadataRoute(protected, sewn)
    /* Tools */
    registerSummarizeRoute(
        protected,
        sewn,
        modelProvider: modelProvider
    )
    /* List */
    registerListDocumentsRoute(protected, sewn)
    registerListGroupsRoute(protected, sewn)
    registerListGroupsByDocumentsRoute(protected, sewn)
    /* Infinite — public group leaderboard and search */
    registerInfiniteRoutes(protected, sewn)
    /* Auth — sign-out and a new password require a live session */
    registerAuthSignOutRoute(protected)
    registerAuthUpdatePasswordRoute(protected)
    /* Account — the provider keys this account is handed */
    registerAccountKeysRoute(protected)
    /* Graph — knowledge-graph query proxy (entity match + neighborhood) */
    registerGraphRoute(protected, sewn)
    /* Personalities — chat personas */
    registerPersonalitiesRoute(protected, sewn)
    /* Profile */
    registerProfileRoute(protected)
    registerUpdateProfileRoute(protected)
    /* Frank — GBT model inspect */
    registerFrankRoutes(protected, sewn)
    /* Marielle — proactive personalization */
    registerMarielleRoutes(protected, sewn, modelProvider: modelProvider)
    /* Speak — Mistral TTS proxy */
    registerSpeakRoute(protected)
    /* Forms — user feedback ingestion */
    registerFeedbackRoute(protected)
    /* Wallet — earnings summary and cashout history */
    registerWalletRoute(protected, sewn)
    /* Admin — privileged cross-account operations, gated by AdminMiddleware */
    let admin = router.add(middleware: AdminMiddleware())
    registerAdminRoutes(admin, sewn)
    registerAdminPersonalitiesRoute(admin, sewn)
}

/// Builds the WebSocket router served through the HTTP1 upgrade channel.
/// Separate from the HTTP router so upgrade matching never scans routes that
/// can't upgrade; bearer auth happens in each route's `shouldUpgrade`.
func configureWebSocketRoutes(
    _ sewn: Sewn,
    modelProvider: ModelProvider
) -> Router<BasicWebSocketRequestContext> {
    let wsRouter = Router(context: BasicWebSocketRequestContext.self)
    registerRealtimeRoute(wsRouter, sewn, modelProvider: modelProvider)
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
        // Never overwrite: a key the launching app hands over (Ambient's
        // Settings) beats the checkout's .env, as in Thread's loader.
        setenv(key, value, 0)
    }
}

// MARK: - Server & CLI

/// Main Server entry point.
@main
struct SewnServer: AsyncParsableCommand {
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

    // @ArgumentParser.Flag(name: .long, help: "Enable Thread gRPC node registration and search fan-out.")
    var enableThreads: Bool = true

    @ArgumentParser.Option(name: .long, help: "gRPC port for Thread registration service (default 9090).")
    var grpcPort: Int = 9091

    @ArgumentParser.Option(name: .long, help: "Directory for on-disk state (default ~/Documents/sewn-db; env SEWN_DATA_DIR).")
    var dataDir: String?

    @ArgumentParser.Flag(name: .long, help: "Hosted server for remote peers: serves /metrics for Alloy, guarded by METRICS_TOKEN.")
    var serverMode: Bool = false

    enum CodingKeys: CodingKey {
        case host, port, vlm
        case enablePromptCache, promptCacheSizeMB, promptCacheTTLMinutes
        case enableThreads, grpcPort, dataDir, serverMode
    }

    @MainActor
    func run() async throws {
        // ── Load .env before anything reads environment variables ────────────
        loadDotEnv()

        // ── Storage root: --data-dir beats SEWN_DATA_DIR beats ~/Documents/sewn-db
        let dataRoot = FilePersistence.configure(
            dataDirectory: dataDir ?? ProcessInfo.processInfo.environment["SEWN_DATA_DIR"])

        // ── Logging ──────────────────────────────────────────────────────────
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = .debug
            return handler
        }
        var logger = Logger(label: "sewn")
        logger.logLevel = .debug
        logger.info("Storage root: \(dataRoot.path)")

        // ── Metrics ──────────────────────────────────────────────────────────
        MetricsSystem.bootstrap(PrometheusMetricsFactory())

        // ── Core services ─────────────────────────────────────────────────────
        let sewn = Sewn()
        let modelProvider = ModelProvider(logger: logger)

        // ── Wire Thread gRPC ───────────────────────────────────────────────────
        if enableThreads {
            let sessionManager = ThreadSessionManager(logger: SewnConduitLogger(base: SewnLogger(logger)))
            let grpcServer = SewnGRPCServer()
            sewn._threadQueryClient = ThreadQueryClient(sessionManager: sessionManager)
            await grpcServer.start(
                registry: sewn.nonisolatedRegistryMutator,
                nodeId: sewn.nodeId,
                host: host,
                grpcPort: grpcPort,
                sessionManager: sessionManager,
                logger: SewnLogger(logger)
            )
            SewnLogger(logger).info("Startup", "Thread gRPC enabled on port \(grpcPort)", service: .startup)
        }

        // ── Router + middleware ───────────────────────────────────────────────
        let router = Router(context: SewnRequestContext.self)
        if StackSecret.isLocalMode {
            // Launched by an app for itself: no browser is a client, so no
            // CORS — and every request must carry the app's secret. Added
            // before any route: Hummingbird binds middleware at registration.
            router.middlewares.add(StackSecretMiddleware<SewnRequestContext>())
        } else {
            router.middlewares.add(CORSMiddleware(
                allowOrigin: .all,
                allowHeaders: [.accept, .authorization, .contentType, .origin, .userAgent, HTTPField.Name("X-Requested-With")!],
                allowMethods: [.get, .post, .delete, .options]
            ))
        }
        router.middlewares.add(IPMetricsMiddleware())

        // ── Register ALL routes before Application.init freezes the responder ─
        configureRoutes(router, sewn, modelProvider: modelProvider, isVLM: vlm, serverMode: serverMode)
        let wsRouter = configureWebSocketRoutes(sewn, modelProvider: modelProvider)

        // ── Build Application AFTER all routes are registered ─────────────────
        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
            configuration: .init(
                address: .hostname(host, port: port),
                serverName: "Sewn"
            ),
            logger: logger
        )

        let sewnLogger = SewnLogger(logger)
        sewnLogger.info("Startup", "Server starting on http://\(host):\(port)", service: .startup)
        let provider = LLMProvider.serverDefault
        sewnLogger.info(
            "Startup",
            "Default provider: \(provider.rawValue) (\(ModelConfig.chatModel(for: provider)))",
            service: .startup)
        if await modelProvider.local.isBuilt {
            let gpu = LocalGPU.report()
            sewnLogger.info(
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
            sewnLogger.info(
                "Startup", "On-device provider: not built (MLX is macOS-only)", service: .startup)
        }
        sewnLogger.info("Startup", "VLM mode: \(vlm ? "enabled" : "disabled")", service: .startup)
        if serverMode {
            let metricsToken = ProcessInfo.processInfo.environment["METRICS_TOKEN"] ?? ""
            if metricsToken.isEmpty {
                sewnLogger.warning(
                    label: "Startup",
                    "Server mode without METRICS_TOKEN: /metrics is open to anyone who can reach \(host):\(port)",
                    service: .startup)
            } else {
                sewnLogger.info("Startup", "Server mode: /metrics guarded by METRICS_TOKEN", service: .startup)
            }
        }
        sewnLogger.info(
            "Startup",
            "Prompt cache: \(enablePromptCache ? "enabled (size: \(promptCacheSizeMB)MB, TTL: \(promptCacheTTLMinutes)min)" : "disabled")",
            service: .startup
        )

        do {
            try await app.runService()
        } catch {
            await sewn.shutdown()
            throw error
        }
        await sewn.shutdown()
    }
}
