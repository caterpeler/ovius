import Foundation

// Bodies and replies of the backend's `/api/v1/uploads/*` routes (`ovius_backend/src/ovius_api/uploads.py`).

// MARK: - POST /uploads/sessions

public struct UploadSessionRequest: Encodable, Sendable, Equatable {
    public struct Recording: Encodable, Sendable, Equatable {
        public var recordingId: String
        public var cameraId: String
        public var locationTag: String?
        public var filename: String
        public var tags: [String]
        /// ISO-8601; the backend stores it as UTC `+00:00`.
        public var timestamp: String
        public var durationS: Double
        public var fps: Double
        public var resolution: String?
        public var chunks: [Chunk]

        private enum CodingKeys: String, CodingKey {
            case recordingId = "recording_id"
            case cameraId = "camera_id"
            case locationTag = "location_tag"
            case filename, tags, timestamp
            case durationS = "duration_s"
            case fps, resolution, chunks
        }
    }

    /// One MP4 the worker joins with the recording's others (`ffmpeg -f concat -c copy`), so each must stand alone.
    public struct Chunk: Encodable, Sendable, Equatable {
        public var chunkIndex: Int
        public var startOffsetS: Double
        public var durationS: Double
        public var byteSize: Int64

        private enum CodingKeys: String, CodingKey {
            case chunkIndex = "chunk_index"
            case startOffsetS = "start_offset_s"
            case durationS = "duration_s"
            case byteSize = "byte_size"
        }
    }

    public var uploadId: String?
    public var siteId: String?
    public var recordings: [Recording]

    private enum CodingKeys: String, CodingKey {
        case uploadId = "upload_id"
        case siteId = "site_id"
        case recordings
    }
}

public struct UploadSessionCreated: Decodable, Sendable, Equatable {
    public let uploadId: String
    public let siteId: String
    public let sessionStatus: String

    private enum CodingKeys: String, CodingKey {
        case uploadId = "upload_id"
        case siteId = "site_id"
        case sessionStatus = "session_status"
    }
}

// MARK: - POST /uploads/chunks/presign

public struct PresignPartsRequest: Encodable, Sendable, Equatable {
    public var uploadId: String
    public var recordingId: String
    public var chunkIndex: Int
    public var partNumbers: [Int]
    /// The multipart upload already started for this chunk, so a retry adds to it instead of starting over.
    public var s3UploadId: String?
    public var expiresIn: Int?

    private enum CodingKeys: String, CodingKey {
        case uploadId = "upload_id"
        case recordingId = "recording_id"
        case chunkIndex = "chunk_index"
        case partNumbers = "part_numbers"
        case s3UploadId = "s3_upload_id"
        case expiresIn = "expires_in"
    }
}

public struct PresignedParts: Decodable, Sendable, Equatable {
    public struct Part: Decodable, Sendable, Equatable {
        public let partNumber: Int
        public let url: URL

        private enum CodingKeys: String, CodingKey {
            case partNumber = "part_number"
            case url
        }
    }

    public let s3UploadId: String
    public let presignedParts: [Part]

    private enum CodingKeys: String, CodingKey {
        case s3UploadId = "s3_upload_id"
        case presignedParts = "presigned_parts"
    }
}

// MARK: - POST /uploads/chunks/complete

public struct CompleteChunkRequest: Encodable, Sendable, Equatable {
    /// S3's own field names, which the backend passes through to `CompleteMultipartUpload`.
    public struct Part: Encodable, Sendable, Equatable {
        public var partNumber: Int
        public var eTag: String

        private enum CodingKeys: String, CodingKey {
            case partNumber = "PartNumber"
            case eTag = "ETag"
        }
    }

    public var uploadId: String
    public var recordingId: String
    public var chunkIndex: Int
    public var s3UploadId: String
    public var parts: [Part]

    private enum CodingKeys: String, CodingKey {
        case uploadId = "upload_id"
        case recordingId = "recording_id"
        case chunkIndex = "chunk_index"
        case s3UploadId = "s3_upload_id"
        case parts
    }
}

public struct ChunkCompleted: Decodable, Sendable, Equatable {
    public let uploadStatus: String
    public let transitionedToReady: Bool?

    private enum CodingKeys: String, CodingKey {
        case uploadStatus = "upload_status"
        case transitionedToReady = "transitioned_to_ready"
    }
}

// MARK: - PUT /uploads/sessions/{upload_id}/heartbeat

public struct UploadHeartbeatRequest: Encodable, Sendable, Equatable {
    public struct Recording: Encodable, Sendable, Equatable {
        public var recordingId: String
        public var uploadedBytes: Int64

        private enum CodingKeys: String, CodingKey {
            case recordingId = "recording_id"
            case uploadedBytes = "uploaded_bytes"
        }
    }

    public var smoothedUploadBps: Double
    public var recordings: [Recording]

    private enum CodingKeys: String, CodingKey {
        case smoothedUploadBps = "smoothed_upload_bps"
        case recordings
    }
}

// MARK: - GET /uploads/sessions/{upload_id}

public struct UploadSessionStatus: Decodable, Sendable, Equatable {
    public struct Recording: Decodable, Sendable, Equatable {
        public let recordingId: String
        public let uploadStatus: String?
        /// `WAITING_FOR_UPLOAD`, `QUEUED`, `PROCESSING_CHUNK`, `COMPLETED`, `FAILED` or `ABORTED`.
        public let processStatus: String?
        /// The worker's own line, e.g. `Frame 225/411 (68.9s/127.0s, skip=8) | 13.2 fps | RTF 0.24x | ETA 14s`.
        public let processStage: String?
        public let processedChunks: Int?
        public let activeChunkFrameProgressPct: Double?
        public let cyclesExtractedSoFar: Int?
        public let lastError: String?

        private enum CodingKeys: String, CodingKey {
            case recordingId = "recording_id"
            case uploadStatus = "upload_status"
            case processStatus = "process_status"
            case processStage = "process_stage"
            case processedChunks = "processed_chunks"
            case activeChunkFrameProgressPct = "active_chunk_frame_progress_pct"
            case cyclesExtractedSoFar = "cycles_extracted_so_far"
            case lastError = "last_error"
        }
    }

    public let uploadId: String
    public let sessionStatus: String
    public let workerStatus: String?
    /// The GPU machine: `stopped`, `pending`, `running`, `stopping` or `unknown`.
    public let workerInstanceState: String?
    public let recordings: [Recording]

    private enum CodingKeys: String, CodingKey {
        case uploadId = "upload_id"
        case sessionStatus = "session_status"
        case workerStatus = "worker_status"
        case workerInstanceState = "worker_instance_state"
        case recordings
    }
}
