//
//  GitaPayload.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/2/25.
//

import Foundation

/// The `Gita.Payload` that utilizes certain Seer and Sinatra data types to
/// match with relevant contributions in the network returning a shared royalty
/// tracked set of information.
extension Gita {
    struct Payload {
        // TODO: dataSets becomes the prediction that is tracked instead.
        var dataSets: [SinatraTrainingData]
        var partitions: [Seer.Partition]
        var documents: [Seer.Document]
        /// Maps partitionId → OracleNodeID for partitions retrieved from peer nodes.
        /// Empty for purely local search results.
        var peerSources: [String: OracleNodeID]
        /// Maps documentId → all registered owner IDs for co-owned documents.
        /// Only documents with 2+ owners need entries; single-owner documents
        /// fall back to `partition.ownerId` inside `royalty(for:coOwners:)`.
        var coOwners: [DocumentID: Set<OwnerID>]

        init(dataSets: [SinatraTrainingData] = [],
             partitions: [Seer.Partition] = [],
             documents: [Seer.Document] = [],
             peerSources: [String: OracleNodeID] = [:],
             coOwners: [DocumentID: Set<OwnerID>] = [:]) {
            // TODO: dataSets becomes the prediction that is tracked instead.
            self.dataSets = dataSets
            self.partitions = partitions
            self.documents = documents
            self.peerSources = peerSources
            self.coOwners = coOwners
        }

        init(_ partition: Seer.Partition) {
            self.dataSets = []
            self.partitions = [partition]
            self.documents = []
            self.peerSources = [:]
            self.coOwners = [:]
        }

        init(_ document: Seer.Document) {
            self.dataSets = []
            self.partitions = []
            self.documents = [document]
            self.peerSources = [:]
            self.coOwners = [:]
        }
    }
}

/* Seer.Partition Helpers */

extension Seer.Partition {
    var asGitaPayload: Gita.Payload {
        Gita.Payload(self)
    }
}

extension Collection where Element == Seer.Partition {
    var asGitaPayload: Gita.Payload {
        Gita.Payload(partitions: self as? [Seer.Partition] ?? [])
    }
}

/* Seer.Document Helpers */

extension Seer.Document {
    var asGitaPayload: Gita.Payload {
        Gita.Payload(self)
    }
}

extension Collection where Element == Seer.Document {
    var asGitaPayload: Gita.Payload {
        Gita.Payload(documents: self as? [Seer.Document] ?? [])
    }
}

