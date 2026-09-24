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
        rule("sinatra-harness")
        print("mode \(s.mode)\(s.coldStart ? " (cold start)" : "")  partitions \(s.partitions), weighted \(s.weightedPartitions)  bias \(s.biasTokens) tokens, max |b| \(f(s.biasMaxAbs, 2))  gate g=\(f(s.gate, 2))  encode \(String(format: "%.1f", s.encodeMs)) ms")
        print("owner: \(s.observations) turns observed, \(s.labelled) measured, reliability \(f(s.reliability, 2)), trained \(s.trainedAt ?? "never")\(s.trainingScheduled ? ", training scheduled now" : "")")
        if let t = s.trace {
            print("trace \(t.traceId) (\(t.level), seed \(t.seed.map(String.init) ?? "–")): \(t.steps) steps, H \(f(t.meanEntropyPre)) → \(f(t.meanEntropyPost)) (ΔH \(signed(t.meanEntropyShift))), KL Σ \(f(t.totalKl)), gain Σ \(signed(t.totalGain)) nats")
            print("  divergence \(f(t.divergenceRate * 100, 1))% (first at \(t.firstDivergenceStep.map(String.init) ?? "–")), argmax flips \(t.flippedArgmaxSteps), mass into mask \(signed(t.meanMassIntoMask, 4))/step, sampled in mask \(f(t.sampledInMaskShare * 100, 1))%")
        }
        if let g = s.grounding {
            guard g.measured else {
                print("grounding: not measured (\(g.skippedReason ?? "unknown"))")
                return
            }
            print("grounding \(f(g.grounding * 100, 1))% of \(g.contentTokens) content tokens, drift \(f(g.drift, 2)) nats (\(f(g.driftShare * 100, 1))% drifting), hallucination risk \(f(g.hallucinationRisk, 3)), parroted \(f(g.parrotShare * 100, 1))%")
            print("  context dependence Σι \(signed(g.contextDependence, 2)) nats, mean KL \(f(g.meanContextKl, 3))  (prefill \(String(format: "%.0f", g.prefillMs)) ms, score \(String(format: "%.0f", g.scoreMs)) ms)")
            for c in g.attribution.sorted(by: { $0.nats > $1.nats }).prefix(6) {
                print("  cites \(pad(c.documentId, 36)) \(pad(f(c.nats, 2), 7)) nats, uptake \(f(c.uptake, 2)), coverage \(f(c.coverage, 2)), parrot \(f(c.parrot, 2))")
            }
        }
    }

    /// The grounding layer of a stored trace: each output token against its context.
    static func grounding(_ g: Trace.Grounding, steps: Int) {
        rule("grounding: what the context did to the answer")
        guard g.measured else {
            print("not measured: \(g.skippedReason ?? "unknown")")
            return
        }
        let s = g.summary
        print("\(s.steps) tokens, \(s.contentTokens) content; prompt \(g.promptTokens), bare \(g.bareTokens), shared \(g.sharedPrefixTokens) (\(g.cacheReused ? "decode cache reused" : "fresh prefill"))")
        print("grounded \(f(s.grounding * 100, 1))%  unsupported \(f(s.unsupportedShare * 100, 1))%  contradicted \(f(s.contradictedShare * 100, 1))%  drift \(f(s.drift, 2)) (\(f(s.driftShare * 100, 1))%, first at \(s.firstDriftStep.map(String.init) ?? "–"))  risk \(f(s.hallucinationRisk, 3))")
        for a in g.attribution {
            print("  \(pad(a.partitionId, 32)) rel \(f(a.relevancy, 2))  nats \(pad(f(a.nats, 2), 7)) uptake \(f(a.uptake, 2))  intent \(f(a.intent, 2))  coverage \(f(a.coverage, 2))  parrot \(f(a.parrot, 2))")
        }
        print("  step  token                 ι        KL      class         drift   the context pushed")
        for step in g.steps.prefix(steps) {
            let klass = step.kind == "function" ? "·" : step.kind
            let pushed = step.drift > 0.05 ? "\(token(step.tuneText)) \(signed(step.tuneNats, 2))" : ""
            print("  \(pad(String(step.index), 4))  \(pad(token(step.text), 20))  \(pad(signed(step.influence, 2), 7))  \(pad(f(step.contextKL, 3), 6))  \(pad(klass, 12))  \(pad(f(step.drift, 2), 6))  \(pushed)")
        }
        if g.steps.count > steps { print("  … \(g.steps.count - steps) more") }
    }

    static func report(_ r: GroundingReportPayload) {
        rule("grounding for \(r.owner) (\(r.rows.count) measured turns)")
        for c in r.correlations {
            print("  r(\(pad(c.x, 15)), \(pad(c.y, 17))) = \(c.pearson.map { String(format: "%.3f", $0) } ?? "  n/a")  (n=\(c.n))")
        }
        for b in r.bins {
            print("  \(pad(b.label, 24)) n=\(pad(String(b.count), 4)) grounding \(b.meanGrounding.map { String(format: "%.3f", $0) } ?? "–")  drift \(b.meanDrift.map { String(format: "%.3f", $0) } ?? "–")  risk \(b.meanRisk.map { String(format: "%.3f", $0) } ?? "–")")
        }
        if !r.citations.isEmpty {
            print("  citations across the band:")
            for c in r.citations.prefix(10) {
                print("    \(pad(c.documentId, 40)) \(pad(String(format: "%.2f", c.nats), 8)) nats over \(c.turns) turns, uptake \(String(format: "%.2f", c.meanUptake))")
            }
        }
        for row in r.mostDrifted {
            print("  drifted: \(row.turnId.prefix(8))  drift \(f(row.drift, 2)) (\(f(row.driftShare * 100, 0))%)  grounding \(f(row.grounding, 2))  risk \(f(row.hallucinationRisk, 3))\(row.steered ? "  steered" : "")")
        }
        if let unmeasured = r.unmeasured, !unmeasured.isEmpty {
            print("  unmeasured: " + unmeasured.map { "\($0.value)× \($0.key)" }.joined(separator: ", "))
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
