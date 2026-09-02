//
//  EmbedVectors.swift
//  Seer
//
//  ONE EMBEDDING, RETURNED. `/v1/embeddings` is an INGEST route: it chunks the
//  text, hashes a document id and fans out into Totem, and answers
//  `{success: true}`. A caller that needs the vector itself — to score against
//  its own corpus, in its own process — has nowhere to ask.
//
//  That caller is Mary. Its routing indexes are built from package-authored
//  trigger sentences and scored on-device; on a machine with no Apple
//  `NLEmbedding` asset it has no vectorizer at all, and every semantic seam
//  abstains. This route is the tier underneath: same vendor, same model, same
//  vector space, reached over the local stack it already talks to.
//
//  Sibling of `/v1/complete`: one POST, one JSON body, no SSE trailer, no
//  `seer` scope object on the wire — nothing here is stored, so nothing here
//  needs an owner or a group.
//
//  PIN: NO STORAGE SIDE EFFECT. If this route ever indexes, a caller warming a
//  corpus of a few hundred trigger sentences would silently fill the user's
//  totem with them.
//

import Foundation
import Hummingbird
import Logging

// MARK: - Wire models

struct EmbedVectorsRequest: Codable {
    /// The texts to embed, in order. The response preserves that order.
    let inputs: [String]
    /// RESERVED, AND CURRENTLY IGNORED. `runAPIEmbedding` pins the vendor
    /// model, so accepting a name here and honouring it are different things —
    /// the response reports what actually ran, never what was asked for.
    /// Wire this through when Seer has a second model to offer.
    let model: String?
}

struct EmbedVectorsResponse: Codable, ResponseEncodable {
    var object: String = "list"
    /// WHAT ACTUALLY PRODUCED THESE VECTORS — never an echo of the request.
    /// A caller must stamp this beside anything it keeps: vectors from two
    /// models are not comparable, and cosine across dimensions fails silently
    /// rather than loudly, so a response that echoed an unhonoured request
    /// would be worse than no label at all.
    let model: String
    /// Length of each vector, so a caller can reject a mismatch without
    /// unpacking one.
    let dimensions: Int
    let data: [EmbedVector]

    enum CodingKeys: String, CodingKey {
        case object, model, dimensions, data
    }
}

struct EmbedVector: Codable {
    let index: Int
    let embedding: [Float]
}

// MARK: - Route

func registerEmbedVectorsRoute(
    _ router: some RouterMethods<SeerRequestContext>
) {
    router.post("/v1/embed") { request, context async throws -> EmbedVectorsResponse in
        let body = try await request.decode(as: EmbedVectorsRequest.self, context: context)
        let logger = context.logger

        // The model `runAPIEmbedding` actually calls. Reported, not echoed.
        let servingModel = "mistral-embed"

        let texts = body.inputs.filter { !$0.isEmpty }
        guard !texts.isEmpty else {
            return EmbedVectorsResponse(model: servingModel, dimensions: 0, data: [])
        }

        let embedded = try await StandaloneGeneration.runAPIEmbedding(texts, logger: logger)

        // THE ORDER IS THE CONTRACT. The caller matches vectors to inputs by
        // position, so a vendor that returns them out of order (or drops one)
        // must not silently shift every later vector onto the wrong text.
        var vectors: [EmbedVector] = []
        for datum in embedded.sorted(by: { $0.index < $1.index }) {
            guard case .floats(let floats) = datum.embedding else { continue }
            vectors.append(EmbedVector(index: datum.index, embedding: floats))
        }
        guard vectors.count == texts.count else {
            throw HTTPError(.badGateway, message: "embedding vendor returned \(vectors.count) vectors for \(texts.count) inputs")
        }

        return EmbedVectorsResponse(
            model: servingModel,
            dimensions: vectors.first?.embedding.count ?? 0,
            data: vectors)
    }
}
