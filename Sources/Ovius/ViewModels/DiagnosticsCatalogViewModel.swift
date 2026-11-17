import Foundation
import Observation

/// Loads the Domain 3 Active Adaptive Diagnostics catalog (`AnomalyPattern`, `OperationalLead`, `DiagnosticCard`).
@MainActor
@Observable
public final class DiagnosticsCatalogViewModel {
    private let databaseManager: DatabaseManager

    public var patterns: [AnomalyPattern] = []
    public var leads: [OperationalLead] = []
    public var cards: [DiagnosticCard] = []
    public var errorMessage: String?

    public init(databaseManager: DatabaseManager? = nil) {
        self.databaseManager = databaseManager ?? .shared
    }

    public func reload() {
        errorMessage = nil
        do {
            patterns = try databaseManager.fetchPatterns(activeOnly: true)
            leads = try databaseManager.fetchLeads(activeOnly: true)
            cards = try databaseManager.fetchDiagnosticCards(includeStaticAudit: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
