//
//  Seer.Tone.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 1/5/26.
//

import Foundation


// See Sinatra, which generates a Seer Tone.

/// Tones are dynamic updates to a `Seer.Partition` a
/// partition holds an embedding of a `Seer.Document`, but
/// over time various interactions in an application can augment
/// the impact, influence, or flavor of a partition during a search
/// and response. A tone reference that is dynamically updated
/// over time is applied to the partitions prior to them being returned
/// after a search request. Responses uses tones to modify
/// the style of the response in wording and speech, hence
/// the word "tone".
extension Seer {
    /// This can be created via the summary endpoint as an added object to return.
    /// Where the summary is run through a sentiment analyzer, maybe a custom one
    /// that maps to certain attributes that impacts the search function of partitions
    /// in the `Partition.Index`.
    struct Tone: Codable {
        
    }
}
