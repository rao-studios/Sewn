//
//  Sinatra.Sentiment.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 1/30/26.
//

import Foundation

extension Sinatra {
    struct Sentiment: Codable {
        enum Kind: Codable, Equatable {
            case positive, negative, neutral, mixed, ambiguous
            case unknown(String)
            
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let rawValue = try container.decode(String.self)
                
                switch rawValue {
                case "positive": self = .positive
                case "negative": self = .negative
                case "neutral": self = .neutral
                case "mixed": self = .mixed
                case "ambiguous": self = .ambiguous
                default: self = .unknown(rawValue)
                }
            }
            
            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .positive: try container.encode("positive")
                case .negative: try container.encode("negative")
                case .neutral: try container.encode("neutral")
                case .mixed: try container.encode("mixed")
                case .ambiguous: try container.encode("ambiguous")
                case .unknown(let value): try container.encode(value)
                }
            }
        }
        
        enum EmotionalTone: Codable, Equatable {
            case angry, frustrated, satisfied, confused, indifferent
            case excited, sarcastic, curious, awkward, anxious
            case relieved, nostalgic, defensive, playful, disappointed
            case hopeful, overwhelmed, amused, skeptical, embarrassed
            case proud, lonely, grateful, receptive
            case other(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let rawValue = try container.decode(String.self)
                
                switch rawValue {
                case "angry": self = .angry
                case "frustrated": self = .frustrated
                case "satisfied": self = .satisfied
                case "confused": self = .confused
                case "indifferent": self = .indifferent
                case "excited": self = .excited
                case "sarcastic": self = .sarcastic
                case "curious": self = .curious
                case "awkward": self = .awkward
                case "anxious": self = .anxious
                case "relieved": self = .relieved
                case "nostalgic": self = .nostalgic
                case "defensive": self = .defensive
                case "playful": self = .playful
                case "disappointed": self = .disappointed
                case "hopeful": self = .hopeful
                case "overwhelmed": self = .overwhelmed
                case "amused": self = .amused
                case "skeptical": self = .skeptical
                case "embarrassed": self = .embarrassed
                case "proud": self = .proud
                case "lonely": self = .lonely
                case "grateful": self = .grateful
                case "receptive": self = .receptive
                default: self = .other(rawValue)
                }
            }
            
            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .angry: try container.encode("angry")
                case .frustrated: try container.encode("frustrated")
                case .satisfied: try container.encode("satisfied")
                case .confused: try container.encode("confused")
                case .indifferent: try container.encode("indifferent")
                case .excited: try container.encode("excited")
                case .sarcastic: try container.encode("sarcastic")
                case .curious: try container.encode("curious")
                case .awkward: try container.encode("awkward")
                case .anxious: try container.encode("anxious")
                case .relieved: try container.encode("relieved")
                case .nostalgic: try container.encode("nostalgic")
                case .defensive: try container.encode("defensive")
                case .playful: try container.encode("playful")
                case .disappointed: try container.encode("disappointed")
                case .hopeful: try container.encode("hopeful")
                case .overwhelmed: try container.encode("overwhelmed")
                case .amused: try container.encode("amused")
                case .skeptical: try container.encode("skeptical")
                case .embarrassed: try container.encode("embarrassed")
                case .proud: try container.encode("proud")
                case .lonely: try container.encode("lonely")
                case .grateful: try container.encode("grateful")
                case .receptive: try container.encode("receptive")
                case .other(let value): try container.encode(value)
                }
            }

            var displayName: String {
                switch self {
                case .other(let value): return value.capitalized
                case .angry: return "Angry"
                case .frustrated: return "Frustrated"
                case .satisfied: return "Satisfied"
                case .confused: return "Confused"
                case .indifferent: return "Indifferent"
                case .excited: return "Excited"
                case .sarcastic: return "Sarcastic"
                case .curious: return "Curious"
                case .awkward: return "Awkward"
                case .anxious: return "Anxious"
                case .relieved: return "Relieved"
                case .nostalgic: return "Nostalgic"
                case .defensive: return "Defensive"
                case .playful: return "Playful"
                case .disappointed: return "Disappointed"
                case .hopeful: return "Hopeful"
                case .overwhelmed: return "Overwhelmed"
                case .amused: return "Amused"
                case .skeptical: return "Skeptical"
                case .embarrassed: return "Embarrassed"
                case .proud: return "Proud"
                case .lonely: return "Lonely"
                case .grateful: return "Grateful"
                case .receptive: return "Receptive"
                }
            }
        }
        
        enum ReactionType: Codable, Equatable {
            case agreement, disagreement, question, clarification
            case emotional, neutral, avoidance, humor, sarcasm
            case deflection, storytelling, venting, praising
            case criticizing, brainstorming, reminscing, testing
            case other(String)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let rawValue = try container.decode(String.self)
                
                switch rawValue {
                case "agreement": self = .agreement
                case "disagreement": self = .disagreement
                case "question": self = .question
                case "clarification": self = .clarification
                case "emotional": self = .emotional
                case "neutral": self = .neutral
                case "avoidance": self = .avoidance
                case "humor": self = .humor
                case "sarcasm": self = .sarcasm
                case "deflection": self = .deflection
                case "storytelling": self = .storytelling
                case "venting": self = .venting
                case "praising": self = .praising
                case "criticizing": self = .criticizing
                case "brainstorming": self = .brainstorming
                case "reminscing": self = .reminscing
                case "testing": self = .testing
                default: self = .other(rawValue)
                }
            }
            
            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .agreement: try container.encode("agreement")
                case .disagreement: try container.encode("disagreement")
                case .question: try container.encode("question")
                case .clarification: try container.encode("clarification")
                case .emotional: try container.encode("emotional")
                case .neutral: try container.encode("neutral")
                case .avoidance: try container.encode("avoidance")
                case .humor: try container.encode("humor")
                case .sarcasm: try container.encode("sarcasm")
                case .deflection: try container.encode("deflection")
                case .storytelling: try container.encode("storytelling")
                case .venting: try container.encode("venting")
                case .praising: try container.encode("praising")
                case .criticizing: try container.encode("criticizing")
                case .brainstorming: try container.encode("brainstorming")
                case .reminscing: try container.encode("reminscing")
                case .testing: try container.encode("testing")
                case .other(let value): try container.encode(value)
                }
            }

            var displayName: String {
                switch self {
                case .other(let value): return value.capitalized
                case .agreement: return "Agreement"
                case .disagreement: return "Disagreement"
                case .question: return "Question"
                case .clarification: return "Clarification"
                case .emotional: return "Emotional"
                case .neutral: return "Neutral"
                case .avoidance: return "Avoidance"
                case .humor: return "Humor"
                case .sarcasm: return "Sarcasm"
                case .deflection: return "Deflection"
                case .storytelling: return "Storytelling"
                case .venting: return "Venting"
                case .praising: return "Praising"
                case .criticizing: return "Criticizing"
                case .brainstorming: return "Brainstorming"
                case .reminscing: return "Reminscing"
                case .testing: return "Testing"
                }
            }
        }
        
        // MARK: - Attentiveness

        struct Attentiveness: Codable {
            enum ReferenceType: String, Codable {
                case directQuote = "direct_quote"
                case paraphrase
                case implicit
                case none
            }

            var referencedContent: Bool
            var referenceType: ReferenceType?
            /// true  = user answered the question the assistant posed.
            /// false = a question was posed but the user did not answer it.
            /// nil   = no question was posed in the assistant response.
            var answeredPosedQuestion: Bool?
            /// true when the user's message extends the assistant's idea with
            /// their own thought rather than just reacting or redirecting.
            var building: Bool

            enum CodingKeys: String, CodingKey {
                case referencedContent      = "referenced_content"
                case referenceType          = "reference_type"
                case answeredPosedQuestion  = "answered_posed_question"
                case building
            }

            /// Weighted attentiveness score in [0, 1].
            var score: Double {
                let referenced = referencedContent ? 0.4 : 0.0
                let answered   = (answeredPosedQuestion == true) ? 0.4 : 0.0
                let built      = building ? 0.2 : 0.0
                return referenced + answered + built
            }
        }

        var sentiment: Kind
        var emotionalTones: [EmotionalTone]
        var reactionTypes: [ReactionType]
        var keyPhrases: [String]
        var confidence: Double
        var notes: String
        /// Attentiveness signals extracted from the user/assistant pair.
        /// Optional for backward compatibility with stored registry data.
        var attentiveness: Attentiveness?

        enum CodingKeys: String, CodingKey {
            case sentiment
            case emotionalTones = "emotional_tones"
            case reactionTypes = "reaction_types"
            case keyPhrases = "key_phrases"
            case confidence
            case notes
            case attentiveness
        }
        
        var description: String {
            """
            \(sentiment)
            \(emotionalTones.map { $0.displayName })
            \(reactionTypes.map { $0.displayName })
            \(keyPhrases)
            \(confidence)
            \(notes)
            ------------------------
            Weight: \(calculateWeight())
            """
        }
    }
}
