import SwiftUI

/// Right-hand detail workspace for managing the selected Domain 2 `Section` and testing its
/// AWS selectors.
public struct ClustersView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable public var viewModel: ClustersViewModel

    @State private var sectionDraft: SectionEditorDraft?

    public init(viewModel: ClustersViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            if let section = viewModel.selectedSection {
                ScrollView {
                    VStack(alignment: .leading, spacing: OviusDesign.Spacing.section) {
                        if let errorMessage = viewModel.errorMessage {
                            DashboardStatusBannerView(
                                title: "Selector Error",
                                message: errorMessage,
                                accent: Tokens.danger,
                                systemImage: "exclamationmark.triangle.fill"
                            )
                        }

                        sectionHeader(for: section)

                        VStack(alignment: .leading, spacing: 0) {
                            Text("Dynamic Recording Selectors")
                                .font(.subheadline.bold())
                                .foregroundStyle(Tokens.text)
                                .padding(.horizontal, OviusDesign.Spacing.standard)
                                .padding(.vertical, OviusDesign.Spacing.compact + 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Tokens.raised)

                            DividerLine()

                            VStack(alignment: .leading, spacing: OviusDesign.Spacing.compact) {
                                LabeledContent("Camera IDs") {
                                    Text(section.cameraIds.isEmpty ? "—" : section.cameraIds.joined(separator: ", "))
                                        .foregroundStyle(Tokens.text)
                                }
                                LabeledContent("Location Tags") {
                                    Text(section.locationTags.isEmpty ? "—" : section.locationTags.joined(separator: ", "))
                                        .foregroundStyle(Tokens.text)
                                }
                                LabeledContent("Custom Tags") {
                                    Text(section.customTags.isEmpty ? "—" : section.customTags.joined(separator: ", "))
                                        .foregroundStyle(Tokens.text)
                                }
                                LabeledContent("Exact Filenames") {
                                    Text(section.filenames.isEmpty ? "—" : section.filenames.joined(separator: ", "))
                                        .foregroundStyle(Tokens.text)
                                }
                                LabeledContent("Assigned Trucks Override") {
                                    Text(section.assignedTrucks.map(String.init) ?? "Auto-detected from telemetry")
                                        .foregroundStyle(Tokens.text2)
                                }
                            }
                            .padding(OviusDesign.Spacing.standard)
                        }
                        .panelSurface(background: Tokens.surface, borderColor: Tokens.border, radius: Tokens.radiusLg)

                        VStack(alignment: .leading, spacing: 0) {
                            Text("Live AWS DynamoDB Selector Test")
                                .font(.subheadline.bold())
                                .foregroundStyle(Tokens.text)
                                .padding(.horizontal, OviusDesign.Spacing.standard)
                                .padding(.vertical, OviusDesign.Spacing.compact + 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Tokens.raised)

                            DividerLine()

                            VStack(alignment: .leading, spacing: OviusDesign.Spacing.standard) {
                                HStack(spacing: OviusDesign.Spacing.standard) {
                                    Button {
                                        Task { await viewModel.testSectionSelector(section) }
                                    } label: {
                                        if viewModel.isTestingSelector {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Label("Test Selector Against AWS", systemImage: "network")
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(viewModel.isTestingSelector)

                                    if let msg = viewModel.selectorTestMessage {
                                        Label(msg, systemImage: "checkmark.circle.fill")
                                            .font(.footnote)
                                            .foregroundStyle(Tokens.success.text)
                                    }
                                }

                                if !viewModel.previewRecordings.isEmpty {
                                    Table(viewModel.previewRecordings) {
                                        TableColumn("Recording ID") { rec in
                                            Text(rec.recordingId).font(.footnote.monospaced())
                                        }
                                        TableColumn("Camera") { rec in
                                            Text(rec.cameraId).font(.footnote)
                                        }
                                        TableColumn("Timestamp") { rec in
                                            Text(rec.formattedTimestampLabel.isEmpty ? rec.timestamp : rec.formattedTimestampLabel)
                                                .font(.footnote.monospacedDigit())
                                        }
                                        TableColumn("Location") { rec in
                                            Text(rec.locationTag).font(.footnote)
                                        }
                                    }
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 220, maxHeight: 340)
                                    .panelSurface(background: Tokens.bg, borderColor: Tokens.border, radius: Tokens.radiusMd)
                                }
                            }
                            .padding(OviusDesign.Spacing.standard)
                        }
                        .panelSurface(background: Tokens.surface, borderColor: Tokens.border, radius: Tokens.radiusLg)
                    }
                    .padding(OviusDesign.Spacing.page)
                }
                .background(Tokens.bg)
            } else {
                ContentUnavailableView(
                    "No Section Selected",
                    systemImage: "square.stack.3d.up",
                    description: Text("Select a section from the Sections list or add a new section to inspect its AWS selectors.")
                )
                .background(Tokens.bg)
            }
        }
        .background(Tokens.bg)
        .navigationTitle(viewModel.selectedSection?.name ?? "Clusters & Sections")
        .navigationSubtitle(viewModel.selectedCluster?.name ?? "")
        .navigationSplitViewColumnWidth(min: OviusDesign.Column.detailMin, ideal: 720)
        .sheet(item: $sectionDraft) { draft in
            SectionEditorSheet(clusterId: draft.clusterId, existingSection: draft.existingSection) { sId, cId, name, cams, locs, tags, files, trucks in
                viewModel.createOrUpdateSection(
                    sectionId: sId,
                    clusterId: cId,
                    name: name,
                    cameraIdsText: cams,
                    locationTagsText: locs,
                    customTagsText: tags,
                    filenamesText: files,
                    assignedTrucksText: trucks
                )
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(for section: Section) -> some View {
        let headerActions = HStack(spacing: OviusDesign.Spacing.compact) {
            Button("Edit Selectors") {
                sectionDraft = .edit(section)
            }
            .buttonStyle(.bordered)

            Button("Delete Section", role: .destructive) {
                viewModel.deleteSection(section)
            }
            .buttonStyle(.bordered)
        }

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: OviusDesign.Spacing.compact) {
                sectionIdentity(section)
                headerActions
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                sectionIdentity(section)
                Spacer(minLength: OviusDesign.Spacing.standard)
                headerActions
            }
        }
    }

    private func sectionIdentity(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: OviusDesign.Spacing.tight) {
            Text(section.name)
                .font(.title2.bold())
                .foregroundStyle(Tokens.text)
            Text("Section ID: \(section.sectionId) • Cluster: \(section.clusterId)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Tokens.text2)
        }
    }
}
