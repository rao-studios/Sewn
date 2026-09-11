//
//  ChatGenerationContext.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 10/28/25.
//

import Foundation
import Logging

struct ChatGenerationContext {
    // let modelContainer: ModelContainer
    // let tokenizer: Tokenizer
    let eosTokenId: Int
    let userInput: UserInput
    let logger: Logger
}
