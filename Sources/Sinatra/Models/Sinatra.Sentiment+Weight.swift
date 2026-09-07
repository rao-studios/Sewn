//
//  Sinatra.Sentiment+Weight.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 2/8/26.
//

import Foundation

extension Sinatra.Sentiment {
    func calculateWeight() -> Double {
        // Base sentiment [-1, 1]
        let sentimentScore: Double = {
            switch sentiment {
            case .positive: return 1.0
            case .mixed: return 0.4
            case .ambiguous: return 0.2
            case .neutral: return 0.0
            case .negative: return -0.6
            case .unknown: return 0.0
            }
        }()
        
        // Tone intensity modifier [0, 1] - normalized by count
        let toneIntensity: Double = {
            guard !emotionalTones.isEmpty else { return 0.5 }
            let sum = emotionalTones.reduce(0.0) { result, tone in
                switch tone {
                // High intensity emotions (strong signal)
                case .angry: return result + 1.0
                case .frustrated: return result + 0.9
                case .excited: return result + 0.95
                case .overwhelmed: return result + 0.95
                case .anxious: return result + 0.85
                case .defensive: return result + 0.85
                case .disappointed: return result + 0.8
                case .embarrassed: return result + 0.8
                case .lonely: return result + 0.9
                    
                // Medium intensity emotions (moderate signal)
                case .curious: return result + 0.7
                case .skeptical: return result + 0.65
                case .confused: return result + 0.6
                case .awkward: return result + 0.6
                case .sarcastic: return result + 0.65
                case .playful: return result + 0.7
                case .amused: return result + 0.7
                case .nostalgic: return result + 0.75
                case .hopeful: return result + 0.75
                    
                // Low intensity / positive emotions (weak signal)
                case .satisfied: return result + 0.8
                case .indifferent: return result + 0.3
                case .relieved: return result + 0.5
                case .proud: return result + 0.75
                case .grateful: return result + 0.8
                case .receptive: return result + 0.7
                    
                case .other: return result + 0.5
                }
            }
            return sum / Double(emotionalTones.count)
        }()
        
        // Reaction quality modifier [0.5, 1.5]
        let reactionModifier: Double = {
            guard !reactionTypes.isEmpty else { return 1.0 }
            let sum = reactionTypes.reduce(0.0) { result, reaction in
                switch reaction {
                // Positive engagement (amplify)
                case .agreement: return result + 1.3
                case .praising: return result + 1.4
                case .brainstorming: return result + 1.3
                case .clarification: return result + 1.2
                case .question: return result + 1.2
                    
                // Neutral/moderate engagement (maintain)
                case .neutral: return result + 1.0
                case .emotional: return result + 1.1
                case .storytelling: return result + 1.1
                case .humor: return result + 1.05
                case .testing: return result + 1.0
                case .reminscing: return result + 1.05
                    
                // Negative/avoidant engagement (dampen)
                case .disagreement: return result + 0.8
                case .avoidance: return result + 0.7
                case .deflection: return result + 0.75
                case .venting: return result + 0.85
                case .criticizing: return result + 0.8
                case .sarcasm: return result + 0.75
                    
                case .other: return result + 1.0
                }
            }
            return sum / Double(reactionTypes.count)
        }()
        
        // Combine: sentiment adjusted by tone intensity, scaled by reaction quality
        let combinedScore = (sentimentScore * toneIntensity) * reactionModifier
        
        // Normalize to [0, 1] and apply confidence as certainty weight
        // Range assumption: [-1.5, 1.5] based on worst/best case combinations
        let normalized = (combinedScore + 1.5) / 3.0
        return max(0.0, min(1.0, normalized)) * confidence
    }
}
