import Darwin
import Foundation

/// The videos kept on this Mac, one per recording (`<recording_id>.<ext>`), so that playing an activity never
/// downloads video from AWS: only its inference results come from the backend.
///
/// Kept in Application Support rather than Caches, which macOS may empty. A file is stored as an APFS clone where it
/// can be, so keeping a video from the same disk takes no extra space until one of the two is changed.
public final class LocalVideoStore: Sendable {
    public static let shared = LocalVideoStore()

    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = support.appendingPathComponent("Ovius/Videos", isDirectory: true)
        }
    }

    /// The recording's video, if this Mac has it.
    public func url(for recordingId: String) -> URL? {
        // Recording IDs may hold dots, so the name minus its extension must be the ID exactly.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.first { !$0.hasSuffix(".partial") && ($0 as NSString).deletingPathExtension == recordingId }
            .map { directory.appendingPathComponent($0) }
    }

    /// Keeps a copy of `source` as the recording's video, replacing any it had. Off the main actor: copying from
    /// another disk can take minutes.
    @discardableResult
    public func store(_ source: URL, recordingId: String) async throws -> URL {
        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension.lowercased()
        let destination = directory.appendingPathComponent("\(recordingId).\(ext)")
        let partial = directory.appendingPathComponent("\(recordingId).\(ext).partial")
        let directory = directory
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: partial)
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            // Clone on APFS, else copy; written beside the final name so a half copy is never taken for the video.
            guard copyfile(source.path, partial.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
                let code = errno
                try? FileManager.default.removeItem(at: partial)
                throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
            }
            // The copy it replaces may have had another extension.
            self.remove(recordingId: recordingId)
            try FileManager.default.moveItem(at: partial, to: destination)
        }.value
        return destination
    }

    public func remove(recordingId: String) {
        while let url = url(for: recordingId) {
            guard (try? FileManager.default.removeItem(at: url)) != nil else { return }
        }
    }

    /// How many videos are kept and the space they take (a clone counts in full, though it shares its blocks).
    public func stats() -> (count: Int, totalBytes: Int64) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let videos = files.filter { !$0.lastPathComponent.hasSuffix(".partial") }
        let bytes = videos.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return (videos.count, bytes)
    }
}
