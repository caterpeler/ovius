import Foundation

public struct OviusError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }

    public init(message: String) {
        self.message = message
    }
}

/// A short command, waited for; its output when it fails.
enum Tool {
    @discardableResult
    static func run(_ executable: URL, _ args: [String], environment: [String: String]? = nil) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OviusError(message: "\(executable.lastPathComponent) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }
}

/// What a pipeline wrote, run elsewhere (on the labeler, on another Mac): its Productivity report's two tables and
/// review.json, in one folder.
public enum ResultsFolder {
    /// The report's and the events' file names in `folder`, or why it is not such a folder.
    public static func read(_ folder: URL) throws -> (reportFile: String, eventsFile: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent("review.json").path) else {
            throw OviusError(message: "\(folder.lastPathComponent) has no review.json: run the pipeline with --review.")
        }
        let csvs = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".csv") }.sorted()
        func header(_ name: String) -> String {
            guard let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent(name)) else { return "" }
            defer { try? handle.close() }
            let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
            return head.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        }
        // The usual names first, then any table with the columns.
        let report = (["report.csv"] + csvs).first { csvs.contains($0) && header($0).hasPrefix("loading_point,") }
        let events = (["events.csv"] + csvs).first { csvs.contains($0) && header($0).hasPrefix("kind,point,truck,") }
        guard let report, let events else {
            throw OviusError(message: "\(folder.lastPathComponent) has no Productivity report tables (report.csv and events.csv).")
        }
        return (report, events)
    }
}
