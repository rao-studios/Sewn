//
//  Render.swift
//  sewn-probe
//

import Foundation

enum Render {
    static func f(_ value: Float, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", value) }
    static func signed(_ value: Float, _ digits: Int = 3) -> String { String(format: "%+.\(digits)f", value) }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? String(text.prefix(width)) : text + String(repeating: " ", count: width - text.count)
    }

    static func token(_ text: String?) -> String {
        guard let text else { return "·" }
        return "\"" + text.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static func rule(_ title: String) {
        print("\n── \(title) " + String(repeating: "─", count: max(0, 70 - title.count)))
    }

    static func sinatra(_ s: SinatraDiagnostics) {
        rule("sinatra-mlx")
        print("mode \(s.mode)\(s.coldStart ? " (cold start)" : "")  partitions \(s.partitions), weighted \(s.weightedPartitions)  bias \(s.biasTokens) tokens, max |b| \(f(s.biasMaxAbs, 2))  gate g=\(f(s.gate, 2))  encode \(String(format: "%.1f", s.encodeMs)) ms")
        if let reward = s.previousReward {
            print("this message labelled the previous turn: R=\(f(reward, 2)) (\(s.previousReplyKind ?? "?"))")
        }
        print("owner: \(s.observations) turns observed, \(s.labelled) labelled, reliability \(f(s.reliability, 2)), trained \(s.trainedAt ?? "never")\(s.trainingScheduled ? ", training scheduled now" : "")")
        if let t = s.trace {
            print("trace \(t.traceId) (\(t.level), seed \(t.seed.map(String.init) ?? "–")): \(t.steps) steps, H \(f(t.meanEntropyPre)) → \(f(t.meanEntropyPost)) (ΔH \(signed(t.meanEntropyShift))), KL Σ \(f(t.totalKl)), gain Σ \(signed(t.totalGain)) nats")
            print("  divergence \(f(t.divergenceRate * 100, 1))% (first at \(t.firstDivergenceStep.map(String.init) ?? "–")), argmax flips \(t.flippedArgmaxSteps), mass into mask \(signed(t.meanMassIntoMask, 4))/step, sampled in mask \(f(t.sampledInMaskShare * 100, 1))%")
        }
    }

    static func trace(_ trace: Trace, steps: Int) {
        rule("per-step impact (\(trace.level), \(trace.mode))")
        if !trace.summary.partitionAttribution.isEmpty {
            print("attribution: " + trace.summary.partitionAttribution.sorted { abs($0.value) > abs($1.value) }.prefix(6).map { "\($0.key) \(signed($0.value, 2))" }.joined(separator: "  "))
        }
        print("  step  sampled               counterfactual        H pre→post     KL       gain    rank   mask")
        for step in trace.steps.prefix(steps) {
            let cf = step.diverged ? token(step.counterfactualText) : "="
            print("  \(pad(String(step.index), 4))  \(pad(token(step.sampledText), 20))  \(pad(cf, 20))  \(f(step.entropyPre, 2))→\(pad(f(step.entropyPost, 2), 6)) \(pad(f(step.kl, 4), 7))  \(pad(signed(step.gain, 2), 6))  \(pad("\(step.rankPre)→\(step.rankPost)", 6)) \(step.inMask ? "●" : " ")\(signed(step.massIntoMask))")
        }
        if trace.steps.count > steps { print("  … \(trace.steps.count - steps) more") }
        heatmap(trace)
    }

    /// Where Sinatra acted: Δp of the mask tokens that moved most (full traces only).
    static func heatmap(_ trace: Trace, columns count: Int = 16, rows limit: Int = 50) {
        guard let mask = trace.mask else { return }
        let rows = trace.steps.prefix(limit).compactMap { step in step.movement.map { (step, $0) } }
        guard !rows.isEmpty else { return }
        var totals = [Float](repeating: 0, count: mask.tokenIds.count)
        for (_, movement) in rows { for (i, v) in movement.enumerated() where i < totals.count { totals[i] += abs(v) } }
        let columns = totals.indices.sorted { totals[$0] > totals[$1] }.prefix(count).filter { totals[$0] > 0 }
        guard !columns.isEmpty else { return }
        rule("where sinatra acted (Δp)")
        print("  legend: '#' +10pp  '+' +1pp  '=' −10pp  '-' −1pp  '·' <1pp")
        for (i, column) in columns.enumerated() {
            print("  col \(pad(String(i), 2)) \(pad(token(mask.tokenTexts?[column]), 16)) bias \(signed(mask.bias[column], 2))")
        }
        for (step, movement) in rows {
            let cells = columns.map { column -> Character in
                let v = column < movement.count ? movement[column] : 0
                switch v {
                case 0.1...: return "#"
                case 0.01..<0.1: return "+"
                case ...(-0.1): return "="
                case ...(-0.01): return "-"
                default: return "·"
                }
            }
            print("  \(pad(String(step.index), 4)) \(String(cells))  \(token(step.sampledText))\(step.diverged ? "  (was \(token(step.counterfactualText)))" : "")")
        }
    }
}
