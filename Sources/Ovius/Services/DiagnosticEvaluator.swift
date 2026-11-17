import Foundation

/// Pure client-side evaluator mapping `SectionMetricsSnapshot` + `ClusterBaselineStats`
/// through Tier 1 `AnomalyPattern` rules and Tier 2 `OperationalLead` hypotheses.
public enum DiagnosticEvaluator {

    /// Evaluates all pattern specs against one section and its cluster baseline.
    public static func evaluatePatterns(
        _ patterns: [PatternRuleSpec],
        snapshot: SectionMetricsSnapshot,
        baseline: ClusterBaselineStats
    ) -> [EvaluatedPattern] {
        patterns.map { spec in
            evaluatePattern(spec, snapshot: snapshot, baseline: baseline)
        }
    }

    /// Evaluates Tier 2 `OperationalLead` rules using evaluated Tier 1 pattern results.
    public static func evaluateLeads(
        _ leads: [LeadRuleSpec],
        patternResults: [EvaluatedPattern]
    ) -> [EvaluatedLead] {
        let byId = Dictionary(uniqueKeysWithValues: patternResults.map { ($0.pattern.patternId, $0) })

        return leads.map { lead in
            let reqResults = lead.requiredPatternIds.compactMap { byId[$0] }
            let supResults = lead.supportingPatternIds.compactMap { byId[$0] }

            // Every required pattern (minimum 1) must match the actual section data.
            let allRequiredTriggered = !reqResults.isEmpty
                && reqResults.count == lead.requiredPatternIds.count
                && reqResults.allSatisfy(\.isTriggered)

            let triggeredSup = supResults.filter(\.isTriggered).count
            let supFraction = supResults.isEmpty ? 1.0 : Double(triggeredSup) / Double(supResults.count)
            let confidence = allRequiredTriggered ? (0.65 + 0.35 * supFraction) : 0.0

            return EvaluatedLead(
                lead: lead,
                requiredResults: reqResults,
                supportingResults: supResults,
                isFlagged: allRequiredTriggered,
                confidenceScore: confidence
            )
        }
        .sorted { lhs, rhs in
            if lhs.isFlagged != rhs.isFlagged { return lhs.isFlagged && !rhs.isFlagged }
            if lhs.confidenceScore != rhs.confidenceScore { return lhs.confidenceScore > rhs.confidenceScore }
            return lhs.lead.leadId < rhs.lead.leadId
        }
    }

    // MARK: - Single Pattern Rule Evaluation

    public static func evaluatePattern(
        _ spec: PatternRuleSpec,
        snapshot: SectionMetricsSnapshot,
        baseline: ClusterBaselineStats
    ) -> EvaluatedPattern {
        let actual = snapshot.value(for: spec.metricKey)
        let mu = baseline.mean(for: spec.metricKey)
        let sigma = baseline.stdDev(for: spec.metricKey)
        let relDelta = baseline.relativeDelta(for: spec.metricKey, value: actual)
        let z = baseline.zScore(for: spec.metricKey, value: actual)

        let requiresPeers = (spec.comparisonMode == .relativeDeltaPct || spec.comparisonMode == .zScore)
        let insufficient = isInsufficientSample(for: spec.metricKey, snapshot: snapshot)
            || (requiresPeers && baseline.sectionSnapshots.count < 2)
        if insufficient {
            return EvaluatedPattern(
                pattern: spec,
                actualValue: actual,
                baselineMean: mu,
                baselineStdDev: sigma,
                relativeDelta: relDelta,
                zScore: z,
                isTriggered: false,
                hasInsufficientData: true
            )
        }

        let triggered: Bool
        switch spec.comparisonMode {
        case .relativeDeltaPct:
            guard let delta = relDelta else {
                triggered = false
                break
            }
            triggered = matchesDirection(value: delta, direction: spec.direction, threshold: spec.thresholdValue)

        case .zScore:
            triggered = matchesDirection(value: z, direction: spec.direction, threshold: spec.thresholdValue)

        case .absoluteValue:
            triggered = matchesDirection(value: actual, direction: spec.direction, threshold: spec.thresholdValue)
        }

        return EvaluatedPattern(
            pattern: spec,
            actualValue: actual,
            baselineMean: mu,
            baselineStdDev: sigma,
            relativeDelta: relDelta,
            zScore: z,
            isTriggered: triggered,
            hasInsufficientData: false
        )
    }

    private static func matchesDirection(
        value: Double,
        direction: AnomalyDirection,
        threshold: Double
    ) -> Bool {
        switch direction {
        case .aboveBaseline:
            return value >= threshold
        case .belowBaseline:
            return value <= threshold
        case .withinBand:
            return abs(value) <= abs(threshold)
        }
    }

    private static func isInsufficientSample(for key: MetricKey, snapshot: SectionMetricsSnapshot) -> Bool {
        switch key {
        case .avgQueueTimeS, .avgSpotTimeS, .avgLoadDurationS, .avgDepartureLagS,
             .volumetricRateM3Hr, .truckArrivalRateHr, .incompleteCycleRatio:
            return snapshot.totalCycleCount == 0
        case .excavatorHangRatio, .trueIdleExcessS, .shiftEdgeIdleRatio,
             .breakWindowIdleExcessS, .hourlySlumpConcentration, .outOfFrameRatio:
            return snapshot.totalSegmentCount == 0
        }
    }
}
