import SwiftUI

/// One video on the Uploads page: its file, where it's from, when it was recorded, its parts and processing.
struct UploadDetailView: View {
    @Bindable var state: UploadsState
    let clustersViewModel: ClustersViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ov.Space.xl) {
                if let video = state.selected {
                    page(video)
                } else {
                    OvEmptyState(systemImage: "arrow.up.doc", title: "No videos yet",
                                 message: "Drop videos on the left, or choose them, to start.")
                        .frame(maxWidth: .infinity, minHeight: 420)
                }
            }
            .padding(Ov.Space.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Ov.canvas)
        .foregroundStyle(Ov.ink)
        .navigationTitle(state.selected?.fileName ?? "Uploads")
        .task { clustersViewModel.reload() }
    }

    @ViewBuilder private func page(_ video: UploadVideo) -> some View {
        header(video)
        if video.stage == .failed, let failure = video.failure {
            OvBanner(.error, title: video.processingFailed ? "Processing failed" : "Upload stopped", message: failure)
        }
        UploadStageTracker(video: video)
        if video.detailsLocked {
            Label("Sent with the details below. The backend keeps them as they were sent, so they can't be changed here. To send this video with other details, add the file again and upload that.",
                  systemImage: "lock.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(Ov.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        Group {
            UploadOriginCard(state: state, video: video, clusters: clustersViewModel.clusters)
            UploadDateCard(state: state, video: video)
        }
        .disabled(video.detailsLocked)
        UploadPartsCard(state: state, video: video)
        UploadProcessingCard(video: video)
    }

    private func header(_ video: UploadVideo) -> some View {
        var details = [FleetAnalysis.hm(video.durationS / 60), video.sizeBytes.formatted(.byteCount(style: .file))]
        if let res = video.resolution { details.append(res + (video.fps.map { " · \(Int($0.rounded())) fps" } ?? "")) }
        details.append("\(video.parts.count) part\(video.parts.count == 1 ? "" : "s")")
        // File names run long: a smaller title than other pages, shortened in the middle so its ending stays.
        return HStack(alignment: .bottom, spacing: Ov.Space.l) {
            VStack(alignment: .leading, spacing: Ov.Space.s) {
                Text(video.fileName)
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.5)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(video.fileName)
                HStack(spacing: Ov.Space.l) {
                    ForEach(details, id: \.self) { Text($0) }
                }
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Ov.ink2)
            }
            Spacer(minLength: Ov.Space.l)
            HStack(spacing: Ov.Space.s) {
                switch video.stage {
                case .needsDetails, .ready:
                    Button { state.remove(video.id) } label: { Label("Remove", systemImage: "trash") }
                        .buttonStyle(.ovQuiet)
                    Button { state.startUpload(video.id) } label: { Label("Upload", systemImage: "arrow.up") }
                        .buttonStyle(.ovPrimary)
                        .disabled(!video.hasDetails)
                        .help(video.hasDetails ? "Send its parts to S3" : "Pick its camera first")
                case .uploading:
                    Button { state.cancelUpload(video.id) } label: { Label("Cancel upload", systemImage: "xmark") }
                        .buttonStyle(.ovSecondary)
                case .failed:
                    Button { state.cancelUpload(video.id) } label: { Text("Cancel") }
                        .buttonStyle(.ovQuiet)
                    Button { state.startUpload(video.id) } label: {
                        Label(video.processingFailed ? "Upload again" : "Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.ovPrimary)
                    .help(video.processingFailed ? "Send the whole video again" : "Send only what S3 doesn't have yet")
                case .processing, .done:
                    EmptyView()
                }
            }
            .fixedSize()
        }
    }
}

// MARK: - Stage tracker

/// Details → Upload → Processing → Ready, with where this video is.
struct UploadStageTracker: View {
    let video: UploadVideo

    private enum StepState { case done, current, failed, upcoming }

    var body: some View {
        let current: Int = switch video.stage {
        case .needsDetails: 0
        case .ready, .uploading: 1
        case .failed: video.processingFailed ? 2 : 1
        case .processing: 2
        case .done: 4
        }
        let steps: [(title: String, note: String)] = [
            ("Details", video.hasDetails ? "Camera set" : "Pick a camera"),
            ("Upload", uploadNote),
            ("Processing", processingNote),
            ("Ready", "Shows on the dashboard"),
        ]
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                let s: StepState = i < current ? .done : (i == current ? (video.stage == .failed ? .failed : .current) : .upcoming)
                HStack(spacing: Ov.Space.s) {
                    ZStack {
                        Circle().fill(fill(s)).frame(width: 26, height: 26)
                        switch s {
                        case .done: Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Ov.positiveInk)
                        case .failed: Image(systemName: "exclamationmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Ov.negativeInk)
                        default: Text("\(i + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(s == .current ? Ov.onInverse : Ov.ink3)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(s == .upcoming ? Ov.ink3 : Ov.ink)
                        Text(step.note).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Ov.ink2).lineLimit(1)
                    }
                    .fixedSize()
                }
                if i < steps.count - 1 {
                    Rectangle()
                        .fill(i < current ? Ov.positiveInk.opacity(0.5) : Ov.hairline)
                        .frame(height: 2)
                        .frame(minWidth: 16, maxWidth: .infinity)
                        .padding(.horizontal, Ov.Space.m)
                }
            }
        }
        .ovCard()
    }

    private var uploadNote: String {
        switch video.stage {
        case .uploading: "\(Int((video.uploadProgress * 100).rounded()))% sent"
        case .failed: video.processingFailed ? "All parts sent" : "Stopped"
        case .processing, .done: "All parts sent"
        default: "\(video.parts.count) part\(video.parts.count == 1 ? "" : "s")"
        }
    }

    private var processingNote: String {
        switch video.stage {
        case .processing(let p): p.map { "\(Int(($0 * 100).rounded()))%" } ?? "Under way"
        case .done: "Finished"
        case .failed where video.processingFailed: "Failed"
        default: "Once uploaded"
        }
    }

    private func fill(_ s: StepState) -> Color {
        switch s {
        case .done: Ov.positiveBg
        case .current: Ov.inverse
        case .failed: Ov.negativeBg
        case .upcoming: Ov.sunken
        }
    }
}

// MARK: - Where it's from

/// Cluster › section › camera, plus location and tags; and the sections the video lands in with them.
struct UploadOriginCard: View {
    let state: UploadsState
    let video: UploadVideo
    let clusters: [Cluster]
    @State private var otherCamera = ""

    var body: some View {
        let cluster = clusters.first { $0.clusterId == video.clusterId }
        let sections = (cluster?.sections ?? []).sorted { $0.sectionId < $1.sectionId }
        let section = sections.first { $0.sectionId == video.sectionId }
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            OvCardHeader("Where it's from", subtitle: "Its camera decides where it shows up: every section whose selectors it matches, in any cluster.")

            HStack(alignment: .top, spacing: Ov.Space.m) {
                picker("Cluster", cluster?.name ?? "Choose", icon: "square.stack.3d.up") {
                    ForEach(clusters, id: \.clusterId) { c in
                        Button(c.name) {
                            state.update(video.id) { $0.clusterId = c.clusterId; $0.sectionId = nil; $0.cameraId = nil; $0.locationTag = "" }
                        }
                    }
                }
                picker("Section", section?.name ?? "Choose", icon: "square.split.2x2") {
                    ForEach(sections, id: \.sectionId) { s in
                        Button(s.name) {
                            state.update(video.id) { v in
                                v.sectionId = s.sectionId
                                if let cam = v.cameraId, !s.cameraIds.isEmpty, !s.cameraIds.contains(cam) { v.cameraId = nil }
                                if !s.locationTags.isEmpty, !s.locationTags.contains(v.locationTag) { v.locationTag = "" }
                                // A section that selects by tag needs the video to carry one of its tags.
                                if !s.customTags.isEmpty, Set(v.tags).isDisjoint(with: s.customTags) {
                                    v.tagsText = (v.tags + [s.customTags[0]]).joined(separator: ", ")
                                }
                            }
                        }
                    }
                }
                .disabled(cluster == nil)
                picker("Camera", video.cameraId ?? "Choose", icon: "video") {
                    ForEach(section?.cameraIds ?? [], id: \.self) { cam in
                        Button(cam) { state.update(video.id) { $0.cameraId = cam } }
                    }
                }
                .disabled(section == nil || section?.cameraIds.isEmpty == true)
            }

            if let section, section.cameraIds.isEmpty {
                OvField("Camera ID (this section doesn't list its cameras)", prompt: "CAM-…", text: Binding(
                    get: { video.cameraId ?? "" },
                    set: { value in state.update(video.id) { $0.cameraId = value.isEmpty ? nil : value } }))
            }

            HStack(alignment: .top, spacing: Ov.Space.m) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Location" + ((section?.locationTags.isEmpty == false) ? " (this section needs one)" : " (optional)"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Ov.ink2)
                    if let tags = section?.locationTags, !tags.isEmpty {
                        OvPillMenu(video.locationTag.isEmpty ? "Choose a location" : video.locationTag, systemImage: "mappin.and.ellipse") {
                            ForEach(tags, id: \.self) { tag in
                                Button(tag) { state.update(video.id) { $0.locationTag = tag } }
                            }
                        }
                    } else {
                        TextField("Location", text: Binding(get: { video.locationTag },
                                                            set: { v in state.update(video.id) { $0.locationTag = v } }),
                                  prompt: Text("e.g. Pit Floor Loading Pocket"))
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .padding(.horizontal, Ov.Space.m)
                            .frame(height: 40)
                            .background(Ov.sunken, in: RoundedRectangle(cornerRadius: Ov.Radius.control, style: .continuous))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                OvField("Tags, separated by commas (optional)", prompt: "section:Alpha", text: Binding(
                    get: { video.tagsText },
                    set: { v in state.update(video.id) { $0.tagsText = v } }))
                    .frame(maxWidth: .infinity)
            }

            landsIn(chosen: section)
        }
        .ovCard()
    }

    private func picker<Content: View>(_ label: String, _ value: String, icon: String,
                                       @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Ov.ink2)
            OvPillMenu(value, systemImage: icon, content: content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The sections it will appear in, checked live; a warning when that's none, or not the one picked.
    @ViewBuilder private func landsIn(chosen: Section?) -> some View {
        let matches = state.sections(for: video, in: clusters)
        VStack(alignment: .leading, spacing: Ov.Space.s) {
            if !video.hasDetails {
                Label("Pick its camera to see where it will show up.", systemImage: "info.circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ov.ink2)
            } else if matches.isEmpty {
                Label("It matches no section, so it won't show on the dashboard. Check its location and tags against the section's selectors.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ov.warningInk)
            } else {
                Text("Shows up in").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Ov.ink2)
                OvFlowLayout(spacing: 6) {
                    ForEach(matches, id: \.section.sectionId) { m in
                        FleetChip(text: "\(m.cluster.name) › \(m.section.name)", ink: Ov.sageInk, fill: Ov.sage)
                    }
                }
                if let chosen, !matches.contains(where: { $0.section.sectionId == chosen.sectionId }) {
                    Label("Not in \(chosen.name): its location or tags don't match that section's selectors.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Ov.warningInk)
                }
            }
        }
        .padding(Ov.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ov.sunken.opacity(0.6), in: RoundedRectangle(cornerRadius: Ov.Radius.control, style: .continuous))
    }
}

// MARK: - Recording date

/// When it was recorded: the file's own date unless changed, since the clock shown in the video can't be trusted.
struct UploadDateCard: View {
    let state: UploadsState
    let video: UploadVideo

    var body: some View {
        let changed = video.metadataDate.map { abs($0.timeIntervalSince(video.recordedAt)) > 59 } ?? true
        VStack(alignment: .leading, spacing: Ov.Space.m) {
            OvCardHeader("Recording date", subtitle: "Taken from the file. Change it if the file was copied or exported later than it was recorded.") {
                if changed, video.metadataDate != nil {
                    Button("Use the file's date") { state.update(video.id) { $0.recordedAt = $0.metadataDate ?? $0.recordedAt } }
                        .buttonStyle(OvButtonStyle(.quiet, size: .small))
                }
            }
            HStack(spacing: Ov.Space.m) {
                DatePicker("Recorded", selection: Binding(get: { video.recordedAt },
                                                          set: { d in state.update(video.id) { $0.recordedAt = d } }),
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .environment(\.timeZone, .gmt)
                Text("UTC").font(.system(size: 12)).foregroundStyle(Ov.ink3)
                Spacer()
                if let date = video.metadataDate {
                    FleetChip(text: changed ? "Changed from the file's date" : "From the file",
                              ink: changed ? Ov.warningInk : Ov.sageInk, fill: changed ? Ov.warningBg : Ov.sage)
                        .help("The file says \(date.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    FleetChip(text: "The file has no date; set it", ink: Ov.warningInk, fill: Ov.warningBg)
                }
            }
        }
        .ovCard()
    }
}

// MARK: - Parts

/// The video's hour-long parts: a strip showing each one's share and state, then a row each.
struct UploadPartsCard: View {
    let state: UploadsState
    let video: UploadVideo

    var body: some View {
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            OvCardHeader("Parts", subtitle: video.parts.count > 1
                         ? "Sent in \(video.parts.count) parts of about an hour each, a few MB at a time, so a dropped connection only resends what was lost."
                         : "Sent in one part, a few MB at a time, so a dropped connection only resends what was lost.")
            GeometryReader { proxy in
                let gap: CGFloat = 3
                let usable = proxy.size.width - gap * CGFloat(max(0, video.parts.count - 1))
                HStack(spacing: gap) {
                    ForEach(video.parts) { part in
                        let width = max(6, usable * part.durationS / max(1, video.durationS))
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Ov.sunken)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(color(part))
                                .frame(width: width * (isFailed(part) ? 1 : part.progress))
                        }
                        .frame(width: width)
                    }
                }
            }
            .frame(height: 14)

            VStack(spacing: 0) {
                ForEach(video.parts) { row($0) }
            }
        }
        .ovCard()
        .animation(.easeOut(duration: 0.12), value: video.uploadProgress)
    }

    private func row(_ part: UploadPart) -> some View {
        HStack(spacing: Ov.Space.m) {
            Text("Part \(part.number)").font(.system(size: 13, weight: .semibold)).frame(width: 56, alignment: .leading)
            Text(part.rangeLabel).foregroundStyle(Ov.ink2).frame(width: 110, alignment: .leading)
            Text(part.sizeBytes.formatted(.byteCount(style: .file))).foregroundStyle(Ov.ink2).frame(width: 80, alignment: .trailing)
            Group {
                switch part.state {
                case .waiting:
                    Text(video.stage == .uploading ? "Waiting" : "Not sent").foregroundStyle(Ov.ink3)
                case .uploading(let p):
                    HStack(spacing: Ov.Space.s) {
                        FleetMeter(fraction: p, color: Ov.sageInk, height: 5)
                        Text("\(Int((p * 100).rounded()))%").frame(width: 36, alignment: .trailing)
                    }
                case .uploaded:
                    Label("Sent", systemImage: "checkmark.circle.fill").foregroundStyle(Ov.positiveInk)
                case .failed(let why):
                    Label(why, systemImage: "xmark.octagon.fill").foregroundStyle(Ov.negativeInk).lineLimit(1).help(why)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12.5).monospacedDigit())
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Ov.hairline).frame(height: 1) }
    }

    private func isFailed(_ part: UploadPart) -> Bool {
        if case .failed = part.state { return true }
        return false
    }

    private func color(_ part: UploadPart) -> Color {
        switch part.state {
        case .uploaded: Ov.positiveInk.opacity(0.7)
        case .uploading: Ov.sageInk
        case .failed: Ov.negativeInk.opacity(0.75)
        case .waiting: .clear
        }
    }
}

// MARK: - Processing

/// What happens after the upload: the backend joins the parts and finds the cycles.
struct UploadProcessingCard: View {
    let video: UploadVideo

    var body: some View {
        VStack(alignment: .leading, spacing: Ov.Space.m) {
            OvCardHeader("Processing", subtitle: "Starts once every part is sent: the GPU worker finds its cycles and machine states.") {
                switch video.stage {
                case .processing: FleetChip(text: "Under way", ink: Ov.warningInk, fill: Ov.warningBg)
                case .done: FleetChip(text: "Finished", ink: Ov.positiveInk, fill: Ov.positiveBg)
                case .failed where video.processingFailed: FleetChip(text: "Failed", ink: Ov.negativeInk, fill: Ov.negativeBg)
                default: FleetChip(text: "Not started")
                }
            }
            switch video.stage {
            case .processing(let p):
                if let p {
                    HStack(spacing: Ov.Space.m) {
                        FleetMeter(fraction: p, color: FleetPalette.queue, height: 8)
                        Text("\(Int((p * 100).rounded()))%").font(.system(size: 13, weight: .semibold).monospacedDigit())
                    }
                }
            case .done:
                Label("Its cycles are ready on the Dashboard, under the sections it shows up in.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ov.positiveInk)
            default:
                EmptyView()
            }
            if let note = video.note {
                Text(note)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Ov.ink2)
                    .textSelection(.enabled)
            }
        }
        .ovCard()
    }
}
