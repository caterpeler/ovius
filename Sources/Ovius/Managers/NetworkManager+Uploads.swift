import Foundation

/// The upload routes (`/api/v1/uploads/*`) and the S3 part uploads they sign. Unlike the telemetry reads these are not
/// retried on the fallback URL: creating a session or completing a chunk is not safe to send twice blindly.
extension NetworkManager {
    public func createUploadSession(_ body: UploadSessionRequest) async throws -> UploadSessionCreated {
        try await sendJSON(method: "POST", path: "uploads/sessions", body: body)
    }

    public func presignParts(_ body: PresignPartsRequest) async throws -> PresignedParts {
        try await sendJSON(method: "POST", path: "uploads/chunks/presign", body: body)
    }

    public func completeChunk(_ body: CompleteChunkRequest) async throws -> ChunkCompleted {
        try await sendJSON(method: "POST", path: "uploads/chunks/complete", body: body)
    }

    /// Keeps the backend's upload ETA fresh; the GPU worker waits for uploads due within 5 minutes before stopping.
    public func sendUploadHeartbeat(uploadId: String, _ body: UploadHeartbeatRequest) async throws {
        let _: IgnoredReply = try await sendJSON(method: "PUT", path: "uploads/sessions/\(uploadId)/heartbeat", body: body)
    }

    public func uploadSessionStatus(uploadId: String) async throws -> UploadSessionStatus {
        try await sendJSON(method: "GET", path: "uploads/sessions/\(uploadId)", body: Optional<IgnoredReply>.none)
    }

    /// Aborts the recording's open multipart uploads; a recording aborted can't be resumed, only uploaded again.
    public func abortUploadRecording(recordingId: String, uploadId: String) async throws {
        let _: IgnoredReply = try await sendJSON(method: "POST", path: "uploads/recordings/\(recordingId)/abort",
                                                 body: ["upload_id": uploadId])
    }

    /// Sends one part's bytes to its pre-signed S3 URL and returns the `ETag` S3 gives it, which completing the chunk
    /// needs. `onProgress` gets the bytes sent so far.
    public nonisolated func putPart(_ data: Data, to url: URL, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 120
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (body, response) = try await session.upload(for: request, from: data, delegate: PartProgressDelegate(onProgress))
        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let raw = String(decoding: body, as: UTF8.self)
            let code = raw.range(of: "(?<=<Code>)[^<]+", options: .regularExpression).map { String(raw[$0]) }
            throw NetworkError.httpError(statusCode: http.statusCode, message: code.map { "S3 \($0)" } ?? "S3 refused the part")
        }
        guard let eTag = http.value(forHTTPHeaderField: "ETag"), !eTag.isEmpty else {
            throw NetworkError.httpError(statusCode: http.statusCode, message: "S3 returned no ETag for the part")
        }
        return eTag
    }

    private func sendJSON<Body: Encodable, Response: Decodable>(method: String, path: String, body: Body?) async throws -> Response {
        let config = currentConfiguration()
        var request = URLRequest(url: config.primaryBaseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = config.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        if let apiKey = config.apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapHTTPError(statusCode: http.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch let error as DecodingError {
            throw NetworkError.decodingFailed("/\(path): \(Self.describe(error))")
        }
    }
}

/// A reply whose content isn't needed (any JSON object decodes as this).
struct IgnoredReply: Codable, Sendable {}

private final class PartProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64) -> Void

    init(_ onProgress: @escaping @Sendable (Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onProgress(totalBytesSent)
    }
}
