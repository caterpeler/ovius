import Foundation
import SQLite3

public struct DatabaseError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One SQLite file. Used from one place at a time (the app's main actor).
public final class Database {
    private var db: OpaquePointer?
    public let path: String
    /// The copy made before this opening's migration steps, if it ran any on a library that had data.
    public private(set) var backup: URL?

    public init(path: String) throws {
        self.path = path
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(db)
            throw DatabaseError(message: "Could not open \(path): \(message)")
        }
        try execute("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw DatabaseError(message: message)
        }
    }

    /// Runs a statement; the row it inserted, if any.
    @discardableResult
    public func run(_ sql: String, _ args: Any?...) throws -> Int64 {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError() }
        return sqlite3_last_insert_rowid(db)
    }

    public func query(_ sql: String, _ args: Any?...) throws -> [Row] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            var values: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: values[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT: values[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT: values[name] = String(cString: sqlite3_column_text(stmt, i))
                default: break
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        for (k, arg) in args.enumerated() {
            let i = Int32(k + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, i)
            case let v as Int64: sqlite3_bind_int64(stmt, i, v)
            case let v as Int: sqlite3_bind_int64(stmt, i, Int64(v))
            case let v as Bool: sqlite3_bind_int64(stmt, i, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, i, v)
            case let v as Date: sqlite3_bind_double(stmt, i, v.timeIntervalSince1970)
            case let v as String: sqlite3_bind_text(stmt, i, v, -1, transient)
            default:
                sqlite3_finalize(stmt)
                throw DatabaseError(message: "Cannot store \(type(of: arg!)) in the database")
            }
        }
        return stmt
    }

    private func lastError() -> DatabaseError {
        DatabaseError(message: String(cString: sqlite3_errmsg(db)))
    }

    // Each step once, in order; PRAGMA user_version counts those done.
    private static let migrations = [
        """
        CREATE TABLE sites (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE);
        CREATE TABLE cameras (
            id INTEGER PRIMARY KEY,
            site_id INTEGER NOT NULL REFERENCES sites(id),
            name TEXT NOT NULL COLLATE NOCASE,
            UNIQUE (site_id, name)
        );
        CREATE TABLE pipelines (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            nodes TEXT NOT NULL,
            report_file TEXT NOT NULL,
            events_file TEXT NOT NULL,
            imported_at REAL NOT NULL
        );
        CREATE TABLE analyses (
            id INTEGER PRIMARY KEY,
            camera_id INTEGER NOT NULL REFERENCES cameras(id),
            pipeline_id INTEGER NOT NULL REFERENCES pipelines(id),
            video_name TEXT NOT NULL,
            start TEXT,
            status TEXT NOT NULL,
            error TEXT,
            metrics TEXT,
            created_at REAL NOT NULL,
            finished_at REAL
        );
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """,
        // Site → Cluster → Camera, and batches: a cluster's cameras analysed together. Each camera so far becomes a
        // cluster of its own, of its name (and ID), and each analysis a batch of one camera (with its ID).
        """
        CREATE TABLE clusters (
            id INTEGER PRIMARY KEY,
            site_id INTEGER NOT NULL REFERENCES sites(id),
            name TEXT NOT NULL COLLATE NOCASE,
            UNIQUE (site_id, name)
        );
        INSERT INTO clusters (id, site_id, name) SELECT id, site_id, name FROM cameras;
        CREATE TABLE cameras_new (
            id INTEGER PRIMARY KEY,
            cluster_id INTEGER NOT NULL REFERENCES clusters(id),
            name TEXT NOT NULL COLLATE NOCASE,
            UNIQUE (cluster_id, name)
        );
        INSERT INTO cameras_new (id, cluster_id, name) SELECT id, id, name FROM cameras;
        DROP TABLE cameras;
        ALTER TABLE cameras_new RENAME TO cameras;
        CREATE TABLE batches (
            id INTEGER PRIMARY KEY,
            cluster_id INTEGER NOT NULL REFERENCES clusters(id),
            pipeline_id INTEGER NOT NULL REFERENCES pipelines(id),
            metrics TEXT,
            error TEXT,
            created_at REAL NOT NULL,
            finished_at REAL
        );
        INSERT INTO batches (id, cluster_id, pipeline_id, created_at, finished_at)
            SELECT id, camera_id, pipeline_id, created_at, finished_at FROM analyses;
        ALTER TABLE analyses ADD COLUMN batch_id INTEGER REFERENCES batches(id);
        UPDATE analyses SET batch_id = id;
        CREATE INDEX analyses_batch ON analyses (batch_id);
        """,
    ]

    /// The schema's version: how many steps it has had.
    public static var version: Int { migrations.count }

    private func migrate() throws {
        let done = Int(try query("PRAGMA user_version").first?.int("user_version") ?? 0)
        guard done < Self.migrations.count else { return }
        // A library with data is copied first, whole and as it is, beside itself.
        if done > 0, path != ":memory:", !path.isEmpty {
            let copy = URL(fileURLWithPath: path + ".before-step-\(done + 1)")
            let target = FileManager.default.fileExists(atPath: copy.path)
                ? URL(fileURLWithPath: copy.path + "-\(Int(Date().timeIntervalSince1970))") : copy
            try execute("VACUUM INTO '\(target.path.replacingOccurrences(of: "'", with: "''"))'")
            backup = target
        }
        // A step may make a table again (SQLite's way to change one), which it cannot with foreign keys on; each
        // step's rows are checked against them before it is kept.
        try execute("PRAGMA foreign_keys = OFF")
        defer { try? execute("PRAGMA foreign_keys = ON") }
        for (k, step) in Self.migrations.enumerated() where k >= done {
            try transaction {
                try execute(step)
                if let broken = try query("PRAGMA foreign_key_check").first {
                    throw DatabaseError(message: "Step \(k + 1) left a row of \(broken.string("table") ?? "?") pointing nowhere.")
                }
                try execute("PRAGMA user_version = \(k + 1)")
            }
        }
    }
}

public struct Row {
    public let values: [String: Any]

    public func int(_ name: String) -> Int64? { values[name] as? Int64 }
    public func double(_ name: String) -> Double? {
        (values[name] as? Double) ?? (values[name] as? Int64).map(Double.init)
    }
    public func string(_ name: String) -> String? { values[name] as? String }
    public func date(_ name: String) -> Date? { double(name).map(Date.init(timeIntervalSince1970:)) }
}
