import SwiftUI

/// Native macOS Settings workspace.
public struct SettingsView: View {
    @Bindable public var viewModel: SettingsViewModel
    public let category: SettingsCategory?
    public let onClearTelemetryCaches: (() -> Void)?

    public init(
        viewModel: SettingsViewModel,
        category: SettingsCategory? = nil,
        onClearTelemetryCaches: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.category = category
        self.onClearTelemetryCaches = onClearTelemetryCaches
    }

    public var body: some View {
        Form {
            if category == nil || category == .endpoint {
                endpointConfigurationSection
                endpointActionsSection
            }

            if category == nil || category == .storage {
                offlineCacheSection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.bg)
        .navigationTitle(category?.title ?? "Settings")
        .navigationSplitViewColumnWidth(min: OviusDesign.Column.detailMin, ideal: 680)
        .task {
            await viewModel.load()
        }
    }

    private var endpointConfigurationSection: some View {
        SwiftUI.Section("AWS Telemetry Endpoint Configuration") {
            TextField("Primary CloudFront API URL", text: $viewModel.primaryBaseURLText)
            TextField("Fallback API Gateway URL (optional)", text: $viewModel.fallbackBaseURLText)
            SecureField("API Key (x-api-key, optional)", text: $viewModel.apiKeyText)

            LabeledContent("Request Timeout (seconds)") {
                TextField("30", value: $viewModel.requestTimeoutSeconds, format: .number.precision(.fractionLength(0)))
                    .frame(minWidth: 80, maxWidth: 140)
                    .multilineTextAlignment(.trailing)
            }

            HStack(spacing: OviusDesign.Spacing.standard) {
                Button(action: runConnectionTest) {
                    if viewModel.isTestingConnection {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(viewModel.isTestingConnection)

                if let connectionResult = viewModel.connectionTestResult {
                    Label(connectionResult, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Tokens.success.text)
                }
            }
        }
    }

    private var endpointActionsSection: some View {
        SwiftUI.Section {
            HStack {
                Button("Reset Defaults", action: resetEndpointDefaults)

                Spacer()

                if let status = viewModel.statusMessage {
                    Label(status, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Tokens.success.text)
                }
                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Tokens.danger.text)
                }

                Button("Save Settings", action: saveEndpointSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var offlineCacheSection: some View {
        SwiftUI.Section("LZFSE Offline Telemetry Cache") {
            LabeledContent("Status") {
                Text(viewModel.diskCacheEnabled ? "Enabled (LZFSE Compressed)" : "Disabled")
                    .foregroundStyle(Tokens.text2)
            }

            LabeledContent("Cached Recordings") {
                Text("\(viewModel.diskCacheFileCount)")
                    .monospacedDigit()
            }

            LabeledContent("Disk Footprint") {
                Text(viewModel.diskCacheTotalBytes, format: .byteCount(style: .file))
                    .monospacedDigit()
            }

            LabeledContent("Location") {
                Text(viewModel.diskCachePath)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Button("Refresh Cache Info", action: viewModel.refreshCacheStats)

                Spacer()

                Button("Clear Offline Cache", role: .destructive, action: clearCacheAndNotify)
                    .disabled(viewModel.diskCacheFileCount == 0)
            }
        }
    }

    private func runConnectionTest() {
        Task { await viewModel.testConnection() }
    }

    private func resetEndpointDefaults() {
        Task { await viewModel.resetDefaults() }
    }

    private func saveEndpointSettings() {
        Task { await viewModel.saveSettings() }
    }

    private func clearCacheAndNotify() {
        viewModel.clearDiskCache()
        onClearTelemetryCaches?()
    }
}
