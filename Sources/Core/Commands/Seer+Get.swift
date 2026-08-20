//
//  Seer+Get.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/1/25.
//

import Foundation
import Logging

extension Seer {
    /// Returns a `Seer.Document` for a filename.
    /// - Parameter key: The filename.
    /// - Returns: Seer.Document object.
    func get(_ key: String) -> Seer.Document? {
        let storage = FilePersistence(key: key,
                                      kind: .basic,
                                      logger: logger.base)
        return storage.restore()
    }
}
