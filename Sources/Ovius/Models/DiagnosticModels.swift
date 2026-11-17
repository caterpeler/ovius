import Foundation
import SwiftData

// MARK: - Tier 1: Anomaly Pattern

@Model
public final class AnomalyPattern {
    @Attribute(.unique)
    public var patternId: String

    public var name: String
    public var details: String
    public var metricKey: MetricKey
    public var comparisonMode: ComparisonMode
    public var direction: AnomalyDirection
    public var thresholdValue: Double
    public var isActive: Bool

    // Inverse targets referenced by OperationalLead's distinct @Relationship annotations.
    public var requiredByLeads: [OperationalLead] = []
    public var supportingForLeads: [OperationalLead] = []

    public init(
        patternId: String,
        name: String,
        details: String,
        metricKey: MetricKey,
        comparisonMode: ComparisonMode,
        direction: AnomalyDirection,
        thresholdValue: Double,
        isActive: Bool = true
    ) {
        self.patternId = patternId
        self.name = name
        self.details = details
        self.metricKey = metricKey
        self.comparisonMode = comparisonMode
        self.direction = direction
        self.thresholdValue = thresholdValue
        self.isActive = isActive
    }
}

// MARK: - Tier 2: Operational Lead

@Model
public final class OperationalLead {
    @Attribute(.unique)
    public var leadId: String

    public var name: String
    public var category: String
    public var details: String
    public var diagnosticIds: [String] = []
    public var isActive: Bool

    @Relationship(deleteRule: .nullify, inverse: \AnomalyPattern.requiredByLeads)
    public var requiredPatterns: [AnomalyPattern] = []

    @Relationship(deleteRule: .nullify, inverse: \AnomalyPattern.supportingForLeads)
    public var supportingPatterns: [AnomalyPattern] = []

    @Relationship(deleteRule: .nullify, inverse: \DiagnosticItem.leads)
    public var diagnostics: [DiagnosticItem] = []

    /// Preserves the per-lead order of appearance (`[0, 1, 2]`) across SwiftData fetches.
    public var orderedDiagnostics: [DiagnosticItem] {
        guard !diagnosticIds.isEmpty else { return diagnostics }
        let byId = Dictionary(uniqueKeysWithValues: diagnostics.map { ($0.diagnosticId, $0) })
        return diagnosticIds.compactMap { byId[$0] }
    }

    public init(
        leadId: String,
        name: String,
        category: String,
        details: String,
        requiredPatterns: [AnomalyPattern] = [],
        supportingPatterns: [AnomalyPattern] = [],
        diagnostics: [DiagnosticItem] = [],
        isActive: Bool = true
    ) {
        self.leadId = leadId
        self.name = name
        self.category = category
        self.details = details
        self.requiredPatterns = requiredPatterns
        self.supportingPatterns = supportingPatterns
        self.diagnostics = diagnostics
        self.diagnosticIds = diagnostics.map(\.diagnosticId)
        self.isActive = isActive
    }
}

// MARK: - Tier 3: Diagnostic Item (1:1 -> DiagnosticCard)

@Model
public final class DiagnosticItem {
    @Attribute(.unique)
    public var diagnosticId: String

    public var name: String
    public var priorityOrder: Int
    public var isActive: Bool

    @Relationship(deleteRule: .cascade, inverse: \DiagnosticCard.diagnostic)
    public var viewCard: DiagnosticCard?

    public var leads: [OperationalLead] = []

    public init(
        diagnosticId: String,
        name: String,
        priorityOrder: Int,
        viewCard: DiagnosticCard? = nil,
        isActive: Bool = true
    ) {
        self.diagnosticId = diagnosticId
        self.name = name
        self.priorityOrder = priorityOrder
        self.viewCard = viewCard
        self.isActive = isActive
    }
}

// MARK: - Tier 3 View Descriptor: Diagnostic Card

@Model
public final class DiagnosticCard {
    @Attribute(.unique)
    public var cardId: String

    public var name: String
    public var widgetType: WidgetType
    public var primaryMetric: MetricKey
    public var secondaryMetric: MetricKey?
    public var showsHorizon: Bool
    public var dateHorizon: String
    public var timeHorizon: String
    public var isStaticAudit: Bool

    public var diagnostic: DiagnosticItem?

    public init(
        cardId: String,
        name: String,
        widgetType: WidgetType,
        primaryMetric: MetricKey,
        secondaryMetric: MetricKey? = nil,
        showsHorizon: Bool = true,
        dateHorizon: String = "14 days (2 wks)",
        timeHorizon: String = "Full Shift (06:00–18:00)",
        isStaticAudit: Bool = false
    ) {
        self.cardId = cardId
        self.name = name
        self.widgetType = widgetType
        self.primaryMetric = primaryMetric
        self.secondaryMetric = secondaryMetric
        self.showsHorizon = showsHorizon
        self.dateHorizon = dateHorizon
        self.timeHorizon = timeHorizon
        self.isStaticAudit = isStaticAudit
    }
}

// MARK: - Resolved Diagnostic View Projection

/// Immutable projection of a pooled, deterministically sorted diagnostic view item.
public struct ActiveDiagnosticViewItem: Identifiable, Sendable {
    public var id: String { diagnosticId }
    public let diagnosticId: String
    public let promptName: String
    public let bestAppearanceIndex: Int
    public let priorityOrder: Int
    public let triggeredByLeadNames: [String]
    public let cardId: String
    public let cardName: String
    public let widgetType: WidgetType
    public let primaryMetric: MetricKey
    public let secondaryMetric: MetricKey?
    public let showsHorizon: Bool
    public let dateHorizon: String
    public let timeHorizon: String
}
