//
//  FrankImportRequest.swift
//  seer-server
//



struct FrankImportRequest: Codable {
    let seer: SeerRequest
    let export: SinatraExport
}
