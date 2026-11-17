import Foundation

/// Sendable snapshot of an `AnomalyPattern` row for pure client-side rule evaluation.
public struct PatternRuleSpec: Identifiable, Sendable, Equatable {
    public var id: String { patternId }
    public let patternId: String
    public let name: String
    public let details: String
    public let metricKey: MetricKey
    public let comparisonMode: ComparisonMode
    public let direction: AnomalyDirection
    public let thresholdValue: Double

    public init(
        patternId: String,
        name: String,
        details: String,
        metricKey: MetricKey,
        comparisonMode: ComparisonMode,
        direction: AnomalyDirection,
        thresholdValue: Double
    ) {
        self.patternId = patternId
        self.name = name
        self.details = details
        self.metricKey = metricKey
        self.comparisonMode = comparisonMode
        self.direction = direction
        self.thresholdValue = thresholdValue
    }

    @MainActor
    public init(pattern: AnomalyPattern) {
        self.init(
            patternId: pattern.patternId,
            name: pattern.name,
            details: pattern.details,
            metricKey: pattern.metricKey,
            comparisonMode: pattern.comparisonMode,
            direction: pattern.direction,
            thresholdValue: pattern.thresholdValue
        )
    }
}

/// Sendable snapshot of an `OperationalLead` row referencing pattern IDs.
public struct LeadRuleSpec: Identifiable, Sendable, Equatable {
    public var id: String { leadId }
    public let leadId: String
    public let name: String
    public let category: String
    public let details: String
    public let requiredPatternIds: [String]
    public let supportingPatternIds: [String]

    public init(
        leadId: String,
        name: String,
        category: String,
        details: String,
        requiredPatternIds: [String],
        supportingPatternIds: [String]
    ) {
        self.leadId = leadId
        self.name = name
        self.category = category
        self.details = details
        self.requiredPatternIds = requiredPatternIds
        self.supportingPatternIds = supportingPatternIds
    }

    @MainActor
    public init(lead: OperationalLead) {
        self.init(
            leadId: lead.leadId,
            name: lead.name,
            category: lead.category,
            details: lead.details,
            requiredPatternIds: lead.requiredPatterns.map(\.patternId),
            supportingPatternIds: lead.supportingPatterns.map(\.patternId)
        )
    }
}

/// Result of evaluating a single Tier 1 `AnomalyPattern` against a `SectionMetricsSnapshot`.
public struct EvaluatedPattern: Identifiable, Sendable, Equatable {
    public var id: String { pattern.patternId }
    public let pattern: PatternRuleSpec
    public let actualValue: Double
    public let baselineMean: Double
    public let baselineStdDev: Double
    public let relativeDelta: Double?
    public let zScore: Double
    public let isTriggered: Bool
    public let hasInsufficientData: Bool
}

/// Result of evaluating a Tier 2 `OperationalLead` across required and supporting patterns.
public struct EvaluatedLead: Identifiable, Sendable, Equatable {
    public var id: String { lead.leadId }
    public let lead: LeadRuleSpec
    public let requiredResults: [EvaluatedPattern]
    public let supportingResults: [EvaluatedPattern]
    public let isFlagged: Bool
    public let confidenceScore: Double

    public var triggeredRequiredCount: Int {
        requiredResults.filter(\.isTriggered).count
    }

    public var triggeredSupportingCount: Int {
        supportingResults.filter(\.isTriggered).count
    }
}
