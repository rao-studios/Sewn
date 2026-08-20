// ResponseCodableConformances.swift
// Hummingbird ResponseCodable conformances for all response types.
// Keeps model files framework-agnostic while wiring up automatic JSON encoding
// via context.responseEncoder (JSONEncoder).

import Hummingbird

// MARK: - Auth
extension SignInResponse: ResponseCodable {}
extension SignUpResponse: ResponseCodable {}

// MARK: - Chat Completions
extension ChatCompletionResponse: ResponseCodable {}
extension ChatCompletionChunkResponse: ResponseCodable {}

// MARK: - Completions
extension CompletionResponse: ResponseCodable {}
extension CompletionChunkResponse: ResponseCodable {}

// MARK: - Embeddings
extension EmbeddingResponse: ResponseCodable {}

// MARK: - Search
extension SearchResponse: ResponseCodable {}

// MARK: - Graph
extension GraphProxyResponse: ResponseCodable {}

// MARK: - Modifications
extension ModificationResponse: ResponseCodable {}
extension GroupModificationResponse: ResponseCodable {}
extension GroupRemoveResponse: ResponseCodable {}
extension GroupMetadataResponse: ResponseCodable {}

// MARK: - List
extension DocumentListResponse: ResponseCodable {}
extension GroupListResponse: ResponseCodable {}
extension GroupsByDocumentsResponse: ResponseCodable {}

// MARK: - Infinite
extension InfiniteLeaderboardResponse: ResponseCodable {}
extension InfiniteSearchResponse: ResponseCodable {}

// MARK: - Admin
extension AdminOwnersResponse: ResponseCodable {}
extension AdminSystemStatsResponse: ResponseCodable {}
extension AdminDeleteOwnerResponse: ResponseCodable {}
extension AdminModelResponse: ResponseCodable {}
extension AuditStaleResponse: ResponseCodable {}
extension AuditReconcileResponse: ResponseCodable {}

// MARK: - Frank / Sinatra
extension FrankGBTResponse: ResponseCodable {}
extension FrankParkingResponse: ResponseCodable {}
extension FrankResetResponse: ResponseCodable {}
extension FrankImportResponse: ResponseCodable {}

// MARK: - Marielle
extension MarielleOpenResponse: ResponseCodable {}
extension MarielleBridgeResponse: ResponseCodable {}
extension MarielleInterjectResponse: ResponseCodable {}
extension MarielleProactiveResponse: ResponseCodable {}

// MARK: - Tools
extension SummarizeResponse: ResponseCodable {}

// MARK: - Wallet
extension WalletResponse: ResponseCodable {}

// MARK: - Totem
extension TotemNodesResponse: ResponseCodable {}

// MARK: - Health
extension HealthResponse: ResponseCodable {}

// MARK: - Stats
extension StatsResponse: ResponseCodable {}

// MARK: - Model List
extension ModelListResponse: ResponseCodable {}

// MARK: - Profile
extension SeerProfile: ResponseCodable {}

// MARK: - Feedback
extension FeedbackResponse: ResponseCodable {}

// MARK: - Sinatra Export
extension SinatraExport: ResponseCodable {}
extension SinatraExportSummary: ResponseCodable {}
