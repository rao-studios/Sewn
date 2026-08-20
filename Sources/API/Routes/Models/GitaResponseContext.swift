//
//  GitaResponseContext.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 12/21/25.
//

import Foundation

struct GitaResponseContext {
    let references: [Seer.DocumentReference]
    let contribution: Gita.Contribution?
}
