import SwiftUI

/// Renders all triggered Diagnostic Cards below the sticky filter deck, dispatching each card
/// to its own View and applying Lead-driven highlighting and filter loading placeholders.
public struct DashboardDiagnosticsSectionView: View {
    @Bindable public var viewModel: DashboardViewModel
    @State private var showDataQualityDetails: Bool = false

    private let gridColumns = [
        GridItem(.adaptive(minimum: 420, maximum: 900), spacing: 12),
    ]

    public init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Diagnostic Views (\(viewModel.activeDiagnostics.count))")
                    .font(.title3.bold())

                if let highlightedName = viewModel.highlightedLeadName {
                    Text("Highlighting cards for \(highlightedName)")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.14))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(.rect(cornerRadius: 5))
                }

                Spacer()
            }

            if viewModel.isInitialLoading || viewModel.isFilteringData {
                SectionLoadingPlaceholderView(
                    title: viewModel.isInitialLoading ? "Fetching First Cluster (1-Month Telemetry)…" : "Updating Diagnostic Views…",
                    subtitle: "Filtering recordings, cycles, and cluster baselines.",
                    minHeight: 220
                )
            } else if let snapshot = viewModel.activeSnapshot {
                if viewModel.activeDiagnostics.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("All Metrics Within Nominal Baseline")
                                .font(.headline)
                            Text("No Tier 2 Operational Leads triggered for this slice. Use the Data Explorer below to inspect raw recordings, cycles, and machine state timings.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    let highlightedIds = viewModel.highlightedDiagnosticIds
                    let hasActiveHighlight = !highlightedIds.isEmpty

                    LazyVGrid(columns: gridColumns, spacing: 12) {
                        ForEach(viewModel.activeDiagnostics) { item in
                            let isHighlighted = highlightedIds.contains(item.diagnosticId)
                            DiagnosticCardContainerView(
                                item: item,
                                isHighlighted: isHighlighted,
                                isDimmed: hasActiveHighlight && !isHighlighted
                            ) {
                                cardContent(for: item, snapshot: snapshot)
                            }
                        }
                    }
                }

                dataQualityAuditStrip(snapshot: snapshot)
            } else {
                ContentUnavailableView(
                    "No Telemetry Loaded",
                    systemImage: "tray",
                    description: Text("Select a valid Cluster and Date Range to load operational telemetry.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
    }

    @ViewBuilder
    private func cardContent(for item: ActiveDiagnosticViewItem, snapshot: SectionMetricsSnapshot) -> some View {
        switch item.cardId {
        case "CARD_QUEUE_WAIT_HISTOGRAM":
            QueueWaitHistogramCardView(snapshot: snapshot, baseline: viewModel.clusterBaseline)
        case "CARD_EXCAVATOR_STATE_BAR":
            ExcavatorStateBarCardView(snapshot: snapshot, baseline: viewModel.clusterBaseline)
        case "CARD_STATE_GANTT_TIMELINE":
            StateGanttTimelineCardView(
                segments: viewModel.ganttSegments,
                audit: viewModel.ganttConcurrencyAudit,
                conflicts: viewModel.ganttConflictIntervals,
                activeRecording: viewModel.activeRecordingForGantt,
                availableRecordings: viewModel.filteredRecordings.sorted { $0.timestamp > $1.timestamp },
                onSelectRecording: { recId in
                    viewModel.selectGanttRecording(recId)
                }
            )
        case "CARD_CYCLE_PHASE_STACK":
            CyclePhaseStackCardView(snapshot: snapshot, baseline: viewModel.clusterBaseline)
        case "CARD_MANEUVER_COMPARISON":
            ManeuverComparisonCardView(snapshot: snapshot, baseline: viewModel.clusterBaseline)
        case "CARD_ARRIVAL_GAP_CHART":
            ArrivalGapHistogramCardView(snapshot: snapshot)
        case "CARD_IDLE_ALLOWANCE_KPI":
            IdleAllowanceKPICardView(
                snapshot: snapshot,
                baseline: viewModel.clusterBaseline,
                idleThresholdS: Int(viewModel.calcConfig.idleThresholdS)
            )
        case "CARD_HOURLY_PRODUCTIVITY_TREND":
            HourlyProductivityTrendCardView(
                snapshot: snapshot,
                baseline: viewModel.clusterBaseline,
                shiftBaseHourUTC: viewModel.filterState.shiftBaseMinuteUTC / 60
            )
        case "CARD_HOURLY_CYCLE_METRIC_TREND":
            HourlyCycleMetricTrendCardView(
                snapshot: snapshot,
                baseline: viewModel.clusterBaseline,
                shiftBaseHourUTC: viewModel.filterState.shiftBaseMinuteUTC / 60
            )
        default:
            IdleAllowanceKPICardView(
                snapshot: snapshot,
                baseline: viewModel.clusterBaseline,
                idleThresholdS: Int(viewModel.calcConfig.idleThresholdS)
            )
        }
    }

    /// Static Data Quality & Rule 4.2/4.3 Sample Coverage View (`CARD_INCOMPLETE_CYCLE_TABLE`).
    private func dataQualityAuditStrip(snapshot: SectionMetricsSnapshot) -> some View {
        let incompleteRows = snapshot.cycleAuditRows.filter { !$0.isComplete }

        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Label("Data Quality & Rule 4.2/4.3 Coverage", systemImage: "checkmark.shield")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("Complete: \(snapshot.completeCycleCount)/\(snapshot.totalCycleCount)")
                        .font(.caption.monospacedDigit())

                    Text("Excluded Cutoffs: \(snapshot.incompleteCycleCount) (\(OviusFormat.percentage(snapshot.value(for: .incompleteCycleRatio))))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(snapshot.incompleteCycleCount > 0 ? Color.orange : Color.secondary)

                    Text("Uncertain (<0.70): \(snapshot.uncertainSegmentCount)/\(snapshot.totalSegmentCount) (\(OviusFormat.percentage(snapshot.uncertainSegmentRatio)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(snapshot.uncertainSegmentCount > 0 ? Color.orange : Color.secondary)

                    Text("Out-of-Frame: \(OviusFormat.percentage(snapshot.value(for: .outOfFrameRatio)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()

                    if !incompleteRows.isEmpty {
                        Button(showDataQualityDetails ? "Hide Cutoffs" : "Inspect Cutoffs (\(incompleteRows.count))") {
                            showDataQualityDetails.toggle()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }

                if showDataQualityDetails && !incompleteRows.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rule 4.2 Boundary Cutoffs Excluded From Mean Cycle Duration (\(OviusFormat.duration(seconds: snapshot.avgCycleDurationS)) complete-only mean):")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        ForEach(Array(incompleteRows.prefix(8))) { row in
                            HStack(spacing: 12) {
                                Text(row.cycleId).font(.caption2.monospaced()).lineLimit(1)
                                Text("\(row.truckLabel) • \(row.excavatorId)").font(.caption2)
                                Text(row.cycleStatus).font(.caption2).foregroundStyle(.orange)
                                Spacer()
                                Text("Total: Excluded (null)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
