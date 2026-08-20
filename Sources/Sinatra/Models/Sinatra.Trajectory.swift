//
//  Sinatra.Trajectory.swift
//  seer-server
//
//  Snapshot of the trajectory signals computed during a single Sinatra.prepare() cycle.
//  Stored in SinatraRegistry and exposed via /v1/frank/parking for debug inspection.
//

import Foundation

struct SinatraTrajectorySnapshot: Codable {
    enum TrainingDecision: String, Codable {
        case train
        case lightTrain = "light_train"
        case discard
        case `defer`
    }

    enum SessionBoundaryReason: String, Codable {
        case paceCollapse       = "pace_collapse"
        case attentivenessZero  = "attentiveness_zero"
        case both
    }

    /// Normalised pace: responseLatency / (assistantWordCount × 0.3), clamped [0, 1].
    let paceScore: Double
    /// Raw seconds between the previous park and this prepare() call.
    let responseLatencySeconds: Double
    /// Word count of the assistant response that was parked last turn.
    let assistantResponseWordCount: Int
    /// Weighted attentiveness score [0, 1].
    let attentivenessScore: Double
    /// Whether the user referenced content from the assistant response.
    let referencedContent: Bool
    /// Whether the user answered a question posed in the assistant response.
    /// nil when no question was posed.
    let answeredPosedQuestion: Bool?
    /// Whether the user extended the assistant's idea with their own thought.
    let building: Bool
    /// The question extracted from the assistant response, if any.
    let posedQuestion: String?
    /// Combined engagement: (paceScore × 0.4) + (attentivenessScore × 0.6).
    let engagementComposite: Double
    /// Gate decision applied to the parked data this cycle.
    let trainingDecision: TrainingDecision
    /// Whether pace + attentiveness both collapsed simultaneously (topic change or re-entry).
    let sessionBoundaryDetected: Bool
    let sessionBoundaryReason: SessionBoundaryReason?
    /// The verbatim excerpt from the assistant response that resonated with the user.
    /// Nil when no resonance was detected this cycle (training gate was not reached).
    let resonanceExcerpt: String?
    /// Document ID under which the resonance partition was stored in the "Resonance" group.
    /// Nil when resonance was detected but the engagement composite was too low to store
    /// (discard/defer), or when no resonance was detected at all.
    let resonanceDocumentId: String?

    enum CodingKeys: String, CodingKey {
        case paceScore                  = "pace_score"
        case responseLatencySeconds     = "response_latency_seconds"
        case assistantResponseWordCount = "assistant_response_word_count"
        case attentivenessScore         = "attentiveness_score"
        case referencedContent          = "referenced_content"
        case answeredPosedQuestion      = "answered_posed_question"
        case building
        case posedQuestion              = "posed_question"
        case engagementComposite        = "engagement_composite"
        case trainingDecision           = "training_decision"
        case sessionBoundaryDetected    = "session_boundary_detected"
        case sessionBoundaryReason      = "session_boundary_reason"
        case resonanceExcerpt           = "resonance_excerpt"
        case resonanceDocumentId        = "resonance_document_id"
    }
}
