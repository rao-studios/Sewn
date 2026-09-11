//
//  GitaContract.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/9/25.
//

import Foundation

/// Smart contract ABI and utilities for Gita document tracking and royalty system
struct GitaContract {
    /// Smart contract ABI for document registration and royalty distribution
    /// This represents a Solidity contract with the following functions:
    /// - registerDocument(string documentId, string ownerId, string partitionId)
    /// - deleteDocument(string documentId)  
    /// - distributeRoyalty(string[] ownerIds, string[] documentIds, uint256[] percentages)
    /// - getDocumentOwner(string documentId) returns (string)
    static let abi = """
    [
        {
            "inputs": [
                {"internalType": "string", "name": "documentId", "type": "string"},
                {"internalType": "string", "name": "ownerId", "type": "string"},
                {"internalType": "string", "name": "partitionId", "type": "string"}
            ],
            "name": "registerDocument",
            "outputs": [],
            "stateMutability": "nonpayable",
            "type": "function"
        },
        {
            "inputs": [
                {"internalType": "string", "name": "documentId", "type": "string"}
            ],
            "name": "deleteDocument",
            "outputs": [],
            "stateMutability": "nonpayable",
            "type": "function"
        },
        {
            "inputs": [
                {"internalType": "string[]", "name": "ownerIds", "type": "string[]"},
                {"internalType": "string[]", "name": "documentIds", "type": "string[]"},
                {"internalType": "uint256[]", "name": "percentages", "type": "uint256[]"}
            ],
            "name": "distributeRoyalty",
            "outputs": [],
            "stateMutability": "payable",
            "type": "function"
        },
        {
            "inputs": [
                {"internalType": "string", "name": "documentId", "type": "string"}
            ],
            "name": "getDocumentOwner",
            "outputs": [
                {"internalType": "string", "name": "", "type": "string"}
            ],
            "stateMutability": "view",
            "type": "function"
        },
        {
            "inputs": [
                {"internalType": "string", "name": "documentId", "type": "string"}
            ],
            "name": "documentExists",
            "outputs": [
                {"internalType": "bool", "name": "", "type": "bool"}
            ],
            "stateMutability": "view",
            "type": "function"
        },
        {
            "anonymous": false,
            "inputs": [
                {"indexed": true, "internalType": "string", "name": "documentId", "type": "string"},
                {"indexed": true, "internalType": "string", "name": "ownerId", "type": "string"},
                {"indexed": false, "internalType": "string", "name": "partitionId", "type": "string"}
            ],
            "name": "DocumentRegistered",
            "type": "event"
        },
        {
            "anonymous": false,
            "inputs": [
                {"indexed": true, "internalType": "string", "name": "documentId", "type": "string"}
            ],
            "name": "DocumentDeleted",
            "type": "event"
        },
        {
            "anonymous": false,
            "inputs": [
                {"indexed": false, "internalType": "string[]", "name": "ownerIds", "type": "string[]"},
                {"indexed": false, "internalType": "string[]", "name": "documentIds", "type": "string[]"},
                {"indexed": false, "internalType": "uint256[]", "name": "percentages", "type": "uint256[]"},
                {"indexed": false, "internalType": "uint256", "name": "totalAmount", "type": "uint256"}
            ],
            "name": "RoyaltyDistributed",
            "type": "event"
        }
    ]
    """
}