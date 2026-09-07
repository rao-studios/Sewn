//
//  Gita.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/2/25.
//

import Foundation
import Logging

/// Ethereum handler, wallet management, royalty checking system.
/// Tracks, puts, deletes, fetches, and the protocol to allow embeddings
/// to be shared with other servers/entities.
class Gita {
    enum Command {
        case put
        case delete
        case inference
    }
    
    internal var logger: SewnLogger
    internal let walletPersistence: FilePersistence
    var walletRegistry: WalletRegistry

    init(logger: Logger) {
        self.logger = SewnLogger(logger)
        let persistence = FilePersistence(key: "wallet_registry", kind: .basic, logger: logger)
        self.walletPersistence = persistence
        self.walletRegistry = persistence.restore() ?? .init()
    }
    
    /// Route database interactions to the Smart Contract APIs.
    /// - Parameters:
    ///   - payload: The payload to identify metadata information to push.
    ///   - command: The database command/interaction type.
    @discardableResult
    func track(_ payload: Gita.Payload,
               command: Command,
               request: SewnRequest? = nil) -> Gita.Result {
        switch command {
        case .put:
            // logger.info("Track", "Stored document.", service: .gita, request: request)

            // Register documents on blockchain
            return .init()
        case .inference:
            return inference(payload, request: request)
        case .delete:
            return .init()
        }
    }
}

// MARK: -- Inference

extension Gita {
    func inference(_ payload: Gita.Payload, request: SewnRequest? = nil) -> Gita.Result {
        let contribution = royalty(
            for: payload.partitions,
            peerSources: payload.peerSources,
            coOwners: payload.coOwners,
            request: request
        )
        logger.info("Royalty", "\n\(contribution.ownersDebugDescription)", service: .gita, request: request)
        return .init(contribution: contribution)
        // Execute royalty distribution on smart contract
    }
}

// MARK: -- Smart Contract Interactions
/*
Funding reasons:
 - Hosting Data
 - Serving LLMs
 - Smart Contract uploads
   - Initial capital required for Smart Contract to hold.
   - Similar to an escrow service
 
 - uploads (free)
   - documents added to the Sewn network
 - inferences (royalty is based off of magnitude split of text/embeddings used per request)
   - documents used, royalty distribution
 - downloads (cost scales with document stats and usage, that's the stock market parallel)
   - textual data, labeled, used for training
   - even if generative data enters, ML companies will help filter valuable data via their downloads and stock dynamics.
 
So, if you write well or create well. Your stock goes up.
 - Simple.
 
ML/AI companies are happy. And Creators have a way out.
 - The Platinum Gate Bridge.
 - You will all feel safe once again.
 -- And those who couldn't make it, will rest peacefully.
 
Mission Accomplished.
*/

//extension Gita {
//    /// Register documents on the blockchain
//    private func registerDocuments(_ documents: [Sewn.Document]) async {
//        for document in documents {
//            do {
//                let txHash = try await registerDocument(
//                    documentId: document.id,
//                    ownerId: document.ownerId,
//                    partitionId: document.partitionId
//                )
//                logger.info("Document \(document.id) registered with tx: \(txHash)")
//            } catch {
//                logger.error("Failed to register document \(document.id): \(error)")
//            }
//        }
//    }
//    
//    /// Delete documents from the blockchain
//    private func deleteDocuments(_ documents: [Sewn.Document]) async {
//        for document in documents {
//            do {
//                let txHash = try await deleteDocument(documentId: document.id)
//                logger.info("Document \(document.id) deleted with tx: \(txHash)")
//            } catch {
//                logger.error("Failed to delete document \(document.id): \(error)")
//            }
//        }
//    }
//    
//    /// Distribute royalties to owners
//    private func distributeRoyalties(_ contribution: Contribution) async {
//        do {
//            let txHash = try await distributeRoyalty(contribution: contribution)
//            logger.info("Royalties distributed with tx: \(txHash)")
//        } catch {
//            logger.error("Failed to distribute royalties: \(error)")
//        }
//    }
//    
//    /// Register a single document on the smart contract
//    private func registerDocument(documentId: String, ownerId: String, partitionId: String) async throws -> String {
//        let contract = web3.contract(GitaContract.abi, at: contractAddress)
//        guard let contract = contract else {
//            throw GitaError.contractNotFound
//        }
//        
//        let parameters: [AnyObject] = [
//            documentId as AnyObject,
//            ownerId as AnyObject,
//            partitionId as AnyObject
//        ]
//        
//        let method = "registerDocument"
//        let tx = contract.createWriteOperation(method: method, parameters: parameters)
//        
//        guard let transaction = tx else {
//            throw GitaError.transactionCreationFailed
//        }
//        
//        transaction.transaction.from = wallet.getAddress()
//        transaction.transaction.gasPrice = .automatic
//        transaction.transaction.gasLimit = .automatic
//        
//        let result = try await transaction.writeToChain(password: "")
//        return result.hash
//    }
//    
//    /// Delete a document from the smart contract
//    private func deleteDocument(documentId: String) async throws -> String {
//        let contract = web3.contract(GitaContract.abi, at: contractAddress)
//        guard let contract = contract else {
//            throw GitaError.contractNotFound
//        }
//        
//        let parameters: [AnyObject] = [documentId as AnyObject]
//        let method = "deleteDocument"
//        let tx = contract.createWriteOperation(method: method, parameters: parameters)
//        
//        guard let transaction = tx else {
//            throw GitaError.transactionCreationFailed
//        }
//        
//        transaction.transaction.from = wallet.getAddress()
//        transaction.transaction.gasPrice = .automatic
//        transaction.transaction.gasLimit = .automatic
//        
//        let result = try await transaction.writeToChain(password: "")
//        return result.hash
//    }
//    
//    /// Distribute royalties based on contribution
//    private func distributeRoyalty(contribution: Contribution) async throws -> String {
//        let contract = web3.contract(GitaContract.abi, at: contractAddress)
//        guard let contract = contract else {
//            throw GitaError.contractNotFound
//        }
//        
//        let owners = Array(contribution.owners)
//        let ownerIds = owners.map { $0.id }
//        let documentIds = owners.map { $0.documentId }
//        let percentages = owners.map { owner in
//            BigUInt((contribution.royalty[owner] ?? 0) * 10000) // Convert to basis points
//        }
//        
//        let parameters: [AnyObject] = [
//            ownerIds as AnyObject,
//            documentIds as AnyObject,
//            percentages as AnyObject
//        ]
//        
//        let method = "distributeRoyalty"
//        let tx = contract.createWriteOperation(method: method, parameters: parameters)
//        
//        guard let transaction = tx else {
//            throw GitaError.transactionCreationFailed
//        }
//        
//        transaction.transaction.from = wallet.getAddress()
//        transaction.transaction.gasPrice = .automatic
//        transaction.transaction.gasLimit = .automatic
//        
//        let result = try await transaction.writeToChain(password: "")
//        return result.hash
//    }
//    
//    /// Query document ownership from the blockchain
//    func getDocumentOwner(documentId: String) async throws -> String? {
//        let contract = web3.contract(GitaContract.abi, at: contractAddress)
//        guard let contract = contract else {
//            throw GitaError.contractNotFound
//        }
//        
//        let parameters: [AnyObject] = [documentId as AnyObject]
//        let method = "getDocumentOwner"
//        let tx = contract.createReadOperation(method: method, parameters: parameters)
//        
//        guard let transaction = tx else {
//            throw GitaError.transactionCreationFailed
//        }
//        
//        let result = try await transaction.callContractMethod()
//        
//        if let ownerAddress = result["0"] as? String {
//            return ownerAddress
//        }
//        
//        return nil
//    }
//
//}


