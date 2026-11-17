import SwiftUI

/// Widget 3: Intra-day shift time-of-day selector filtering `haul_cycles` and `state_segments` across active dates.
public struct TimeRangeSelectorWidget: View {
    @Bindable public var viewModel: DashboardViewModel

    @State private var startHourOffset: Int = 0
    @State private var endHourOffset: Int = 12

    public init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Time Range (UTC)", systemImage: "clock")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    let baseMin = viewModel.filterState.shiftBaseMinuteUTC
                    Text("\(DashboardFilterState.shiftClockString(offsetS: viewModel.filterState.todStartS, baseMinuteUTC: baseMin))–\(DashboardFilterState.shiftClockString(offsetS: viewModel.filterState.todEndS, baseMinuteUTC: baseMin))")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                }

                // Quick Shift Window Chips
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 4)], spacing: 4) {
                    ForEach([
                        ShiftTimePreset.fullShift,
                        .startupEdge,
                        .morning,
                        .middayBreak,
                        .afternoon,
                        .closingEdge,
                    ]) { preset in
                        let isSelected = viewModel.filterState.timePreset == preset
                        Button {
                            viewModel.applyTimePreset(preset)
                        } label: {
                            VStack(spacing: 1) {
                                Text(preset.rawValue)
                                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                                Text(preset.clockLabel(using: viewModel.calcConfig))
                                    .font(.system(size: 9).monospacedDigit())
                                    .opacity(0.85)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.14))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .clipShape(.rect(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()

                // Custom Hour Window Pickers synced to configured shift base
                HStack(spacing: 8) {
                    Picker("From", selection: $startHourOffset) {
                        ForEach(0..<12, id: \.self) { hr in
                            Text(DashboardFilterState.shiftClockString(offsetS: Double(hr) * 3600.0, baseMinuteUTC: viewModel.filterState.shiftBaseMinuteUTC)).tag(hr)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 80)
                    .onChange(of: startHourOffset) { _, newStart in
                        if endHourOffset <= newStart {
                            endHourOffset = min(12, newStart + 1)
                        }
                    }

                    Text("to")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("To", selection: $endHourOffset) {
                        ForEach((startHourOffset + 1)...12, id: \.self) { hr in
                            Text(DashboardFilterState.shiftClockString(offsetS: Double(hr) * 3600.0, baseMinuteUTC: viewModel.filterState.shiftBaseMinuteUTC)).tag(hr)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 80)

                    Spacer()

                    Button("Apply") {
                        let lo = min(startHourOffset, max(0, endHourOffset - 1))
                        let hi = max(lo + 1, endHourOffset)
                        viewModel.applyCustomTimeRange(startS: Double(lo) * 3600.0, endS: Double(hi) * 3600.0)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { syncHours() }
        .onChange(of: viewModel.filterState.todStartS) { _, _ in syncHours() }
        .onChange(of: viewModel.filterState.todEndS) { _, _ in syncHours() }
    }

    private func syncHours() {
        startHourOffset = max(0, min(11, Int((viewModel.filterState.todStartS / 3600.0).rounded(.down))))
        endHourOffset = max(startHourOffset + 1, min(12, Int((viewModel.filterState.todEndS / 3600.0).rounded(.up))))
    }
}
