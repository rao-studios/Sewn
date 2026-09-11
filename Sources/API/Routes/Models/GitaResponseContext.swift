//
//  GitaResponseContext.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 12/21/25.
//

import Foundation

struct GitaResponseContext {
    let references: [Sewn.DocumentReference]
    let contribution: Gita.Contribution?
}
