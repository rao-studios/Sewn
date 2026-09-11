//
//  Sewn+Get.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/1/25.
//

import Foundation
import Logging

extension Sewn {
    /// Returns a `Sewn.Document` for a filename.
    /// - Parameter key: The filename.
    /// - Returns: Sewn.Document object.
    func get(_ key: String) -> Sewn.Document? {
        let storage = FilePersistence(key: key,
                                      kind: .basic,
                                      logger: logger.base)
        return storage.restore()
    }
}
