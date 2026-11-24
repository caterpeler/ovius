import SwiftUI

/// The Settings page: the AWS endpoint, the offline telemetry cache and the videos kept on this Mac.
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
        ScrollView {
            VStack(alignment: .leading, spacing: Ov.Space.xl) {
                if category == nil || category == .endpoint {
                    OvPageHeader("AWS endpoint", details: ["Where Ovius reads telemetry from"]) { EmptyView() }
                    endpointCard
                    endpointActions
                }
                if category == nil || category == .storage {
                    OvPageHeader("Offline cache", details: ["Telemetry kept on this Mac, compressed"]) { EmptyView() }
                    offlineCacheCard
                    LocalVideosCard()
                }
            }
            .padding(Ov.Space.page)
            .frame(maxWidth: 820, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Ov.canvas)
        .foregroundStyle(Ov.ink)
        .navigationTitle(category?.title ?? "Settings")
        .task {
            await viewModel.load()
        }
    }

    private var endpointCard: some View {
        VStack(alignment: .leading, spacing: Ov.Space.m) {
            OvCardHeader("Telemetry endpoint", subtitle: "Ovius asks the main address first and the fallback when it can't reach it.")
            OvField("Main CloudFront API address", prompt: "https://…/api/v1", text: $viewModel.primaryBaseURLText)
            OvField("Fallback API Gateway address (optional)", prompt: "https://…/v1", text: $viewModel.fallbackBaseURLText)
            OvField("API key (x-api-key, optional)", prompt: "Not set", text: $viewModel.apiKeyText, isSecure: true)
            OvField("Request timeout, in seconds", prompt: "30", text: timeoutText)
                .frame(maxWidth: 260)
            HStack(spacing: Ov.Space.m) {
                Button(action: runConnectionTest) {
                    if viewModel.isTestingConnection {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Test connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .buttonStyle(.ovSecondary)
                .disabled(viewModel.isTestingConnection)

                if let connectionResult = viewModel.connectionTestResult {
                    Label(connectionResult, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Ov.positiveInk)
                }
            }
            .padding(.top, Ov.Space.xs)
        }
        .ovCard()
    }

    private var endpointActions: some View {
        HStack(spacing: Ov.Space.m) {
            Button("Reset to defaults", action: resetEndpointDefaults)
                .buttonStyle(.ovQuiet)
            Spacer()
            if let status = viewModel.statusMessage {
                Label(status, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Ov.positiveInk)
            }
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Ov.negativeInk)
            }
            Button("Save settings", action: saveEndpointSettings)
                .buttonStyle(.ovPrimary)
        }
    }

    private var offlineCacheCard: some View {
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            OvCardHeader("Cached telemetry", subtitle: "Recordings already downloaded, and their box tracks, open without asking the cloud again.") {
                FleetChip(text: viewModel.diskCacheEnabled ? "On" : "Off",
                          ink: viewModel.diskCacheEnabled ? Ov.sageInk : Ov.ink2,
                          fill: viewModel.diskCacheEnabled ? Ov.sage : Ov.sunken)
            }
            HStack(spacing: Ov.Space.m) {
                stat("Recordings cached", "\(viewModel.diskCacheFileCount)")
                stat("Space used", viewModel.diskCacheTotalBytes.formatted(.byteCount(style: .file)))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Location").font(.system(size: 12)).foregroundStyle(Ov.ink2)
                Text(viewModel.diskCachePath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Ov.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Refresh", action: viewModel.refreshCacheStats)
                    .buttonStyle(OvButtonStyle(.secondary, size: .small))
                Spacer()
                Button("Clear offline cache", role: .destructive, action: clearCacheAndNotify)
                    .buttonStyle(OvButtonStyle(.destructive, size: .small))
                    .disabled(viewModel.diskCacheFileCount == 0)
            }
        }
        .ovCard()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Ov.ink2)
            Text(value).font(.system(size: 22, weight: .medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Ov.Space.m)
        .background(Ov.sunken.opacity(0.6), in: RoundedRectangle(cornerRadius: Ov.Radius.control, style: .continuous))
    }

    /// The timeout as text for its field; whole seconds above zero are kept.
    private var timeoutText: Binding<String> {
        Binding(
            get: { String(Int(viewModel.requestTimeoutSeconds)) },
            set: { if let v = Double($0.trimmingCharacters(in: .whitespaces)), v > 0 { viewModel.requestTimeoutSeconds = v } }
        )
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

/// The uploaded videos kept on this Mac for playing activities. There's no button to clear them: unlike the cache,
/// they can't be fetched again (the app never downloads video), so they're removed in Finder, on purpose.
private struct LocalVideosCard: View {
    var store: LocalVideoStore = .shared
    @State private var stats: (count: Int, totalBytes: Int64) = (0, 0)

    var body: some View {
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            OvCardHeader("Videos on this Mac", subtitle: "Every video uploaded from here is kept, so its activities play without downloading it again. Copies on the same disk share space with the original.")
            HStack(spacing: Ov.Space.m) {
                stat("Videos kept", "\(stats.count)")
                stat("Space used", stats.totalBytes.formatted(.byteCount(style: .file)))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Location").font(.system(size: 12)).foregroundStyle(Ov.ink2)
                Text(store.directory.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Ov.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Refresh") { stats = store.stats() }
                    .buttonStyle(OvButtonStyle(.secondary, size: .small))
                Spacer()
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([store.directory])
                }
                .buttonStyle(OvButtonStyle(.secondary, size: .small))
            }
        }
        .ovCard()
        .task { stats = store.stats() }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(Ov.ink2)
            Text(value).font(.system(size: 22, weight: .medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Ov.Space.m)
        .background(Ov.sunken.opacity(0.6), in: RoundedRectangle(cornerRadius: Ov.Radius.control, style: .continuous))
    }
}
