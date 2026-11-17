import CryptoKit
import Foundation

/// Thread-safe LZFSE-compressed on-disk cache storing immutable per-recording telemetry (`cycles` + `segments`)
/// under the user's macOS `Caches` directory, bypassed and cleared whenever the user triggers an explicit Refresh.
public final class TelemetryDiskCache: Sendable {
    public static let shared = TelemetryDiskCache()

    public struct Entry: Codable, Sendable {
        public let recordingId: String
        public let cycles: [HaulCycleDTO]
        public let segments: [StateSegmentDTO]
        public let cachedAt: Date
    }

    private let baseDirectory: URL
    public let isEnabled: Bool

    public var storageDirectoryURL: URL { baseDirectory }

    public init(directory: URL? = nil, isEnabled: Bool = true) {
        self.isEnabled = isEnabled
        if let directory {
            self.baseDirectory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.baseDirectory = caches.appendingPathComponent("ovius_telemetry_cache", isDirectory: true)
        }
    }

    public func load(recordingId: String, namespace: String) -> Entry? {
        guard isEnabled else { return nil }
        let fileURL = cacheFileURL(recordingId: recordingId, namespace: namespace)
        guard let compressed = try? Data(contentsOf: fileURL) else { return nil }
        guard let decompressed = try? (compressed as NSData).decompressed(using: .lzfse) as Data else {
            return nil
        }
        return try? JSONDecoder().decode(Entry.self, from: decompressed)
    }

    public func save(
        recordingId: String,
        cycles: [HaulCycleDTO],
        segments: [StateSegmentDTO],
        namespace: String
    ) {
        guard isEnabled else { return }
        let fileURL = cacheFileURL(recordingId: recordingId, namespace: namespace)
        let dirURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            let entry = Entry(
                recordingId: recordingId,
                cycles: cycles,
                segments: segments,
                cachedAt: .now
            )
            let encoded = try JSONEncoder().encode(entry)
            let compressed = try (encoded as NSData).compressed(using: .lzfse) as Data
            try compressed.write(to: fileURL, options: [.atomic])
        } catch {
            // Disk caching is strictly best-effort; network cache still operates cleanly.
        }
    }

    public func clearAll() {
        guard isEnabled else { return }
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    public func cacheStats() -> (fileCount: Int, totalBytes: Int64) {
        guard isEnabled,
              let enumerator = FileManager.default.enumerator(
                  at: baseDirectory,
                  includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return (0, 0)
        }

        var count = 0
        var totalBytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            count += 1
            totalBytes += Int64(values.fileSize ?? 0)
        }
        return (count, totalBytes)
    }

    private func cacheFileURL(recordingId: String, namespace: String) -> URL {
        let nsDigest = sha256Hex(namespace).prefix(16)
        let recDigest = sha256Hex(recordingId)
        return baseDirectory
            .appendingPathComponent(String(nsDigest), isDirectory: true)
            .appendingPathComponent("\(recDigest).lzfse", isDirectory: false)
    }

    private func sha256Hex(_ raw: String) -> String {
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
