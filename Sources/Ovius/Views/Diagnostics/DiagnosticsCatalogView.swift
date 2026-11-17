import SwiftUI

private enum CatalogTier: String, CaseIterable, Identifiable {
    case leads = "Tier 2: Operational Leads (9)"
    case patterns = "Tier 1: Anomaly Patterns (15)"
    case cards = "Tier 3: Diagnostic Cards (9 + 1 Audit)"

    var id: String { rawValue }
}

/// Read-only explorer for the Domain 3 Active Adaptive Diagnostics catalog seeded in SwiftData.
public struct DiagnosticsCatalogView: View {
    @Bindable public var viewModel: DiagnosticsCatalogViewModel
    @State private var selectedTier: CatalogTier = .leads

    public init(viewModel: DiagnosticsCatalogViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Catalog Tier", selection: $selectedTier) {
                ForEach(CatalogTier.allCases) { tier in
                    Text(tier.rawValue).tag(tier)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 16)

            if let errorMessage = viewModel.errorMessage {
                GroupBox {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 20)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    switch selectedTier {
                    case .leads:
                        ForEach(viewModel.leads, id: \.leadId) { lead in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(lead.name)
                                            .font(.headline)
                                        Text(lead.leadId)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(lead.category)
                                            .font(.caption)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.14))
                                            .clipShape(.rect(cornerRadius: 4))
                                    }

                                    Text(lead.details)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)

                                    HStack(spacing: 12) {
                                        Text("Required: \(lead.requiredPatterns.map(\.patternId).joined(separator: ", "))")
                                            .font(.caption)
                                        if !lead.supportingPatterns.isEmpty {
                                            Text("Supporting: \(lead.supportingPatterns.map(\.patternId).joined(separator: ", "))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text("Diagnostic sequence: \(lead.orderedDiagnostics.map(\.diagnosticId).joined(separator: " → "))")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                    case .patterns:
                        ForEach(viewModel.patterns, id: \.patternId) { pattern in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(pattern.name)
                                            .font(.headline)
                                        Text(pattern.patternId)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(pattern.metricKey.rawValue) • \(pattern.comparisonMode.rawValue)")
                                            .font(.caption.monospaced())
                                    }
                                    Text(pattern.details)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text("Direction: \(pattern.direction.rawValue) • Threshold: \(String(format: "%.2f", pattern.thresholdValue))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                    case .cards:
                        ForEach(viewModel.cards, id: \.cardId) { card in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(card.name)
                                            .font(.headline)
                                        Text(card.cardId)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(card.widgetType.rawValue)
                                            .font(.caption.monospaced())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(card.isStaticAudit ? Color.blue.opacity(0.14) : Color.secondary.opacity(0.14))
                                            .clipShape(.rect(cornerRadius: 4))
                                    }
                                    HStack(spacing: 16) {
                                        Text("Primary: \(card.primaryMetric.rawValue)")
                                        if let sec = card.secondaryMetric {
                                            Text("Secondary: \(sec.rawValue)")
                                        }
                                        Text("Horizon: \(card.dateHorizon) • \(card.timeHorizon)")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Adaptive Diagnostic Rules")
        .onAppear {
            viewModel.reload()
        }
    }
}
