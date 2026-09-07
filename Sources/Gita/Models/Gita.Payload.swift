//
//  GitaPayload.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/2/25.
//

import Foundation

/// The `Gita.Payload` that utilizes certain Sewn and Sinatra data types to
/// match with relevant contributions in the network returning a shared royalty
/// tracked set of information.
extension Gita {
    struct Payload {
        // TODO: dataSets becomes the prediction that is tracked instead.
        var dataSets: [SinatraTrainingData]
        var partitions: [Sewn.Partition]
        var documents: [Sewn.Document]
        /// Maps partitionId → OracleNodeID for partitions retrieved from peer nodes.
        /// Empty for purely local search results.
        var peerSources: [String: OracleNodeID]
        /// Maps documentId → all registered owner IDs for co-owned documents.
        /// Only documents with 2+ owners need entries; single-owner documents
        /// fall back to `partition.ownerId` inside `royalty(for:coOwners:)`.
        var coOwners: [DocumentID: Set<OwnerID>]

        init(dataSets: [SinatraTrainingData] = [],
             partitions: [Sewn.Partition] = [],
             documents: [Sewn.Document] = [],
             peerSources: [String: OracleNodeID] = [:],
             coOwners: [DocumentID: Set<OwnerID>] = [:]) {
            // TODO: dataSets becomes the prediction that is tracked instead.
            self.dataSets = dataSets
            self.partitions = partitions
            self.documents = documents
            self.peerSources = peerSources
            self.coOwners = coOwners
        }

        init(_ partition: Sewn.Partition) {
            self.dataSets = []
            self.partitions = [partition]
            self.documents = []
            self.peerSources = [:]
            self.coOwners = [:]
        }

        init(_ document: Sewn.Document) {
            self.dataSets = []
            self.partitions = []
            self.documents = [document]
            self.peerSources = [:]
            self.coOwners = [:]
        }
    }
}

/* Sewn.Partition Helpers */

extension Sewn.Partition {
    var asGitaPayload: Gita.Payload {
        Gita.Payload(self)
    }
}

extension Collection where Element == Sewn.Partition {
    var asGitaPayload: Gita.Payload {
        Gita.Payload(partitions: self as? [Sewn.Partition] ?? [])
    }
}

/* Sewn.Document Helpers */

extension Sewn.Document {
    var asGitaPayload: Gita.Payload {
        Gita.Payload(self)
    }
}

extension Collection where Element == Sewn.Document {
    var asGitaPayload: Gita.Payload {
        Gita.Payload(documents: self as? [Sewn.Document] ?? [])
    }
}

