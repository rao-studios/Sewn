//
//  FrankImportResponse.swift
//  seer-server
//



/// Returned by `POST /v1/frank/import`.
struct FrankImportResponse: Codable {
    /// Always `true` — the import was applied. Present for symmetry with reset.
    let imported: Bool
    /// The owner ID that received the imported data (the auth'd requester, not the exporter).
    let ownerId: String
    /// Lightweight summary of what was imported.
    let summary: SinatraExportSummary

    enum CodingKeys: String, CodingKey {
        case imported
        case ownerId  = "owner_id"
        case summary
    }
}
