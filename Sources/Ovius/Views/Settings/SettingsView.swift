import SwiftUI

/// Native macOS Settings workspace editing Domain 2 `AppSettings` and `NetworkManager.Configuration`.
public struct SettingsView: View {
    @Bindable public var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            SwiftUI.Section("Volumetric Payload Assumptions (m³ per Cycle)") {
                LabeledContent("Mean Payload (m³)") {
                    TextField("51.1", value: $viewModel.meanPayloadM3, format: .number.precision(.fractionLength(1)))
                        .frame(width: 110)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Struck Payload (m³)") {
                    TextField("42.1", value: $viewModel.struckPayloadM3, format: .number.precision(.fractionLength(1)))
                        .frame(width: 110)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Heaped Payload (m³)") {
                    TextField("60.1", value: $viewModel.heapedPayloadM3, format: .number.precision(.fractionLength(1)))
                        .frame(width: 110)
                        .multilineTextAlignment(.trailing)
                }
            }

            SwiftUI.Section("Locked Business Rules & Shift Schedule (UTC)") {
                LabeledContent("Stationary Idle Allowance (seconds — Rule 4.1)") {
                    HStack(spacing: 8) {
                        TextField("300", value: $viewModel.idleThresholdS, format: .number)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $viewModel.idleThresholdS, in: 0...1800, step: 30)
                            .labelsHidden()
                    }
                }

                LabeledContent("Shift Edge Window (minutes)") {
                    HStack(spacing: 8) {
                        TextField("60", value: $viewModel.shiftEdgeWindowMin, format: .number)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $viewModel.shiftEdgeWindowMin, in: 10...180, step: 15)
                            .labelsHidden()
                    }
                }

                TextField("Shift Start Hours (HH:mm, comma-separated)", text: $viewModel.shiftStartHoursText)
                TextField("Break Windows (HH:mm-HH:mm, comma-separated)", text: $viewModel.breakWindowsText)
            }

            SwiftUI.Section("AWS Telemetry Endpoint Configuration") {
                TextField("Primary CloudFront API URL", text: $viewModel.primaryBaseURLText)
                TextField("Fallback API Gateway URL (optional)", text: $viewModel.fallbackBaseURLText)
                SecureField("API Key (x-api-key, optional)", text: $viewModel.apiKeyText)

                LabeledContent("Request Timeout (seconds)") {
                    TextField("30", value: $viewModel.requestTimeoutSeconds, format: .number.precision(.fractionLength(0)))
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await viewModel.testConnection() }
                    } label: {
                        if viewModel.isTestingConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                    .disabled(viewModel.isTestingConnection)

                    if let connectionResult = viewModel.connectionTestResult {
                        Text(connectionResult)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            SwiftUI.Section {
                HStack {
                    Button("Reset Defaults") {
                        Task { await viewModel.resetDefaults() }
                    }

                    Spacer()

                    if let status = viewModel.statusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button("Save Settings") {
                        Task { await viewModel.saveSettings() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            await viewModel.load()
        }
    }
}
