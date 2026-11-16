import CryptoKit
import Foundation

/// Sets up the Python the pipelines run with: a standalone CPython 3.12 for this Mac, from python-build-standalone
/// (the builds uv and others use), checked against its release's checksum and unpacked into the library.
public enum PythonSetup {
    static let releases = URL(string: "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest")!

    /// Downloads and unpacks it; the python3 it set up. `progress` hears each step and how far a download is.
    public static func install(into library: Library, progress: @escaping @Sendable (String, Double?) -> Void) async throws -> URL {
        let fm = FileManager.default
        try library.make()
        progress("Finding Python for this Mac", nil)
        let asset = try await latestAsset()
        let archive = library.downloads.appendingPathComponent(asset.name)
        defer { try? fm.removeItem(at: archive) }
        progress("Downloading Python", 0)
        try await download(asset.url, to: archive) { progress("Downloading Python", $0) }

        progress("Checking the download", nil)
        let sha = try await expectedSHA256(of: asset)
        guard try sha256(of: archive) == sha else {
            throw OviusError(message: "The Python download did not match its checksum; try again.")
        }

        progress("Unpacking Python", nil)
        let staging = library.root.appendingPathComponent(".python-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try Tool.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", staging.path])
        let unpacked = staging.appendingPathComponent("python", isDirectory: true)
        try Tool.run(unpacked.appendingPathComponent("bin/python3"), ["--version"])
        if fm.fileExists(atPath: library.python.path) { try fm.removeItem(at: library.python) }
        try fm.moveItem(at: unpacked, to: library.python)
        // A venv made with another Python points at it: start the packages again with this one.
        if fm.fileExists(atPath: library.venv.path) { try fm.removeItem(at: library.venv) }
        guard let python = library.setUpPython else { throw OviusError(message: "The Python download held no bin/python3.") }
        return python
    }

    struct Asset {
        var name: String
        var url: URL
        var digest: String?
        var checksums: URL?
    }

    static func latestAsset() async throws -> Asset {
        var request = URLRequest(url: releases)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ovius", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = release["assets"] as? [[String: Any]] else {
            throw OviusError(message: "Could not read Python's latest release from GitHub.")
        }
        return try pick(from: assets)
    }

    /// CPython 3.12's install-only build for this Mac's chip, from a release's assets.
    static func pick(from assets: [[String: Any]]) throws -> Asset {
        #if arch(arm64)
        let arch = "aarch64"
        #else
        let arch = "x86_64"
        #endif
        let wanted = try Regex("^cpython-3\\.12\\.\\d+\\+\\d+-\(arch)-apple-darwin-install_only\\.tar\\.gz$")
        let url = { (asset: [String: Any]) in (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        guard let asset = assets.first(where: { ($0["name"] as? String)?.wholeMatch(of: wanted) != nil }),
              let name = asset["name"] as? String, let download = url(asset) else {
            throw OviusError(message: "Python's latest release has no build for this Mac (\(arch)).")
        }
        let digest = (asset["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        let sums = assets.first { $0["name"] as? String == "SHA256SUMS" }.flatMap(url)
        return Asset(name: name, url: download, digest: digest, checksums: sums)
    }

    static func expectedSHA256(of asset: Asset) async throws -> String {
        if let digest = asset.digest { return digest.lowercased() }
        guard let sums = asset.checksums else { throw OviusError(message: "Python's release gives no checksum to check the download with.") }
        let (data, _) = try await URLSession.shared.data(from: sums)
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == asset.name {
                return parts[0].lowercased()
            }
        }
        throw OviusError(message: "Python's release lists no checksum for \(asset.name).")
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        let receiver = Receiver(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: receiver, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                receiver.done = done
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private final class Receiver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @Sendable (Double?) -> Void
        var done: CheckedContinuation<Void, Error>?
        var failed: Error?

        init(destination: URL, progress: @escaping @Sendable (Double?) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
                failed = OviusError(message: "The Python download failed (HTTP \(status)).")
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                failed = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error ?? failed {
                done?.resume(throwing: error)
            } else {
                done?.resume()
            }
            done = nil
        }
    }
}
