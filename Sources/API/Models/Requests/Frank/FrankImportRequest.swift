//
//  FrankImportRequest.swift
//  sewn-server
//



struct FrankImportRequest: Codable {
    let sewn: SewnRequest
    let export: SinatraExport
}
