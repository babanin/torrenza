import Foundation
import Darwin
import SQLite3

public struct SQLiteEntry: Sendable {
    public let namespace: String
    public let key: String
    public let value: Data?

    public init(namespace: String, key: String, value: Data?) {
        self.namespace = namespace
        self.key = key
        self.value = value
    }
}

public enum SQLiteStoreError: Error, LocalizedError, Sendable {
    case database(code: Int32, message: String)
    case invalid(String)
    case futureVersion(Int32)

    public var errorDescription: String? {
        switch self {
        case let .database(_, message): "Library database: \(message)"
        case let .invalid(message): "Library database: \(message)"
        case let .futureVersion(version): "This library uses a newer database version (\(version))."
        }
    }
}

/// One app-owned metadata file. DELETE journals exist only while a transaction is in progress.
/// All SQLite and filesystem calls run on a dedicated serial queue, never a Swift executor.
public actor SQLiteStore {
    private let worker: SQLiteWorker
    private let queue = DispatchQueue(label: "app.torrenza.sqlite", qos: .utility)

    public init(url: URL) { worker = SQLiteWorker(url: url) }

    public func read(namespace: String, key: String) async throws -> Data? {
        try await perform { try $0.read(namespace: namespace, key: key) }
    }

    public func readAll(namespace: String) async throws -> [String: Data] {
        try await perform { try $0.readAll(namespace: namespace) }
    }

    /// Enumerates records without retaining their potentially large values.
    public func keys(namespace: String) async throws -> [String] {
        try await perform { try $0.keys(namespace: namespace) }
    }

    /// Applies all namespaces in one durable transaction. A nil value deletes the record.
    public func write(_ entries: [SQLiteEntry]) async throws {
        try await perform { worker in
            try worker.transaction {
                for entry in entries { try worker.write(entry) }
            }
        }
    }

    public func replace(namespace: String, values: [String: Data]) async throws {
        try await perform { worker in
            try worker.transaction {
                // Preserve unchanged blobs instead of rewriting the entire namespace.
                let existing = try worker.keys(namespace: namespace)
                for key in existing where values[key] == nil {
                    try worker.write(SQLiteEntry(namespace: namespace, key: key, value: nil))
                }
                for (key, value) in values {
                    try worker.write(SQLiteEntry(namespace: namespace, key: key, value: value))
                }
            }
        }
    }

    /// Releases the connection. A later operation lazily opens it again.
    public func close() async throws { try await perform { try $0.close() } }

    public func integrityCheck() async throws {
        try await perform { worker in
            try worker.open()
            let statement = try worker.prepare("PRAGMA integrity_check")
            defer { sqlite3_finalize(statement) }
            var results: [String] = []
            while try worker.next(statement) { results.append(try worker.string(statement, column: 0)) }
            guard results == ["ok"] else { throw SQLiteStoreError.invalid("Integrity check failed: \(results.joined(separator: "; "))") }
        }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (SQLiteWorker) throws -> T) async throws -> T {
        let worker = worker
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation(worker) }) }
        }
    }
}

// Only accessed by SQLiteStore's serial queue. The final reference cannot disappear during an operation.
private final class SQLiteWorker: @unchecked Sendable {
    let url: URL
    private var database: OpaquePointer?
    private let maximumBytes = 128 * 1_024 * 1_024
    private let maximumTextBytes = 1_024 * 1_024
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) { self.url = url }
    deinit { if let database { sqlite3_close_v2(database) } }

    func open() throws {
        if database != nil { return }
        guard url.isFileURL, !url.path.utf8.contains(0), !url.lastPathComponent.isEmpty else {
            throw SQLiteStoreError.invalid("Expected a local database file URL")
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw fileError("Open database directory") }
        defer { Darwin.close(root) }
        guard fchmod(root, 0o700) == 0 else { throw fileError("Protect database directory") }
        let descriptor = openat(root, url.lastPathComponent, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw fileError("Open database file") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw SQLiteStoreError.invalid("Database must be a regular file without hard links")
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw fileError("Protect database file") }
        var connection: OpaquePointer?
        // macOS /var and /tmp are symlinks; canonicalize the parent, never the database file.
        guard let canonicalParent = realpath(directory.path, nil) else { throw fileError("Resolve database directory") }
        defer { free(canonicalParent) }
        let sqlitePath = String(cString: canonicalParent) + "/" + url.lastPathComponent
        let status = sqlite3_open_v2(sqlitePath, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard status == SQLITE_OK, let connection else {
            let error = SQLiteStoreError.database(code: status, message: connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database")
            if let connection { sqlite3_close_v2(connection) }
            throw error
        }
        database = connection
        do {
            sqlite3_extended_result_codes(connection, 1)
            sqlite3_busy_timeout(connection, 5_000)
            sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, Int32(maximumBytes + maximumTextBytes * 2 + 1024))
            let versionStatement = try prepare("PRAGMA user_version")
            let version: Int32
            do {
                defer { sqlite3_finalize(versionStatement) }
                guard try next(versionStatement) else { throw SQLiteStoreError.invalid("Missing schema version") }
                version = sqlite3_column_int(versionStatement, 0)
            }
            guard version <= 1 else { throw SQLiteStoreError.futureVersion(version) }
            guard version >= 0 else { throw SQLiteStoreError.invalid("Invalid schema version") }
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA fullfsync=ON")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA temp_store=MEMORY")
            try execute("PRAGMA trusted_schema=OFF")
            if version == 0 {
                try transaction {
                    let schema = try prepare("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")
                    defer { sqlite3_finalize(schema) }
                    guard try !next(schema) else { throw SQLiteStoreError.invalid("Unrecognized unversioned database") }
                    try execute("CREATE TABLE records(namespace TEXT NOT NULL, key TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(namespace,key)) WITHOUT ROWID")
                    try execute("PRAGMA user_version=1")
                }
            }
            let validation = try prepare("SELECT namespace, key, value FROM records LIMIT 0")
            sqlite3_finalize(validation)
        } catch {
            sqlite3_close_v2(connection)
            database = nil
            throw error
        }
    }

    func close() throws {
        guard let database else { return }
        let result = sqlite3_close(database)
        guard result == SQLITE_OK else { throw failure(result) }
        self.database = nil
    }

    func transaction(_ body: () throws -> Void) throws {
        try open()
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func read(namespace: String, key: String) throws -> Data? {
        try open()
        let statement = try prepare("SELECT value FROM records WHERE namespace=? AND key=?")
        defer { sqlite3_finalize(statement) }
        try bind(namespace, to: statement, index: 1)
        try bind(key, to: statement, index: 2)
        return try next(statement) ? blob(statement, column: 0) : nil
    }

    func readAll(namespace: String) throws -> [String: Data] {
        try open()
        let statement = try prepare("SELECT key,value FROM records WHERE namespace=?")
        defer { sqlite3_finalize(statement) }
        try bind(namespace, to: statement, index: 1)
        var result: [String: Data] = [:]
        var total = 0
        while try next(statement) {
            let key = try string(statement, column: 0)
            let count = Int(sqlite3_column_bytes(statement, 1)) + key.utf8.count + 64
            guard count <= maximumBytes - total else { throw SQLiteStoreError.invalid("Namespace exceeds read budget") }
            total += count
            result[key] = try blob(statement, column: 1)
        }
        return result
    }

    func keys(namespace: String) throws -> [String] {
        try open()
        let statement = try prepare("SELECT key FROM records WHERE namespace=?")
        defer { sqlite3_finalize(statement) }
        try bind(namespace, to: statement, index: 1)
        var result: [String] = []
        var total = 0
        while try next(statement) {
            let key = try string(statement, column: 0)
            total += key.utf8.count + 32
            guard total <= maximumBytes else { throw SQLiteStoreError.invalid("Namespace exceeds key budget") }
            result.append(key)
        }
        return result
    }

    func write(_ entry: SQLiteEntry) throws {
        let sql = entry.value == nil
            ? "DELETE FROM records WHERE namespace=? AND key=?"
            : "INSERT INTO records(namespace,key,value) VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET value=excluded.value WHERE records.value!=excluded.value"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(entry.namespace, to: statement, index: 1)
        try bind(entry.key, to: statement, index: 2)
        if let value = entry.value {
            guard value.count <= maximumBytes else { throw SQLiteStoreError.invalid("Value exceeds 128 MiB limit") }
            let result = value.isEmpty ? sqlite3_bind_zeroblob(statement, 3, 0) : value.withUnsafeBytes {
                sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient)
            }
            guard result == SQLITE_OK else { throw failure(result) }
        }
        guard try !next(statement) else { throw SQLiteStoreError.invalid("Unexpected write result") }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw failure(result) }
        return statement
    }

    private func execute(_ sql: String) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw failure(result) }
    }

    func next(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        guard result == SQLITE_DONE else { throw failure(result) }
        return false
    }

    private func bind(_ text: String, to statement: OpaquePointer, index: Int32) throws {
        guard text.utf8.count <= maximumTextBytes else { throw SQLiteStoreError.invalid("Key or namespace exceeds 1 MiB limit") }
        let result = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), transient) }
        guard result == SQLITE_OK else { throw failure(result) }
    }

    func string(_ statement: OpaquePointer, column: Int32) throws -> String {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= maximumTextBytes, let bytes = sqlite3_column_text(statement, column),
              let result = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8) else {
            throw SQLiteStoreError.invalid("Invalid database text")
        }
        return result
    }

    private func blob(_ statement: OpaquePointer, column: Int32) throws -> Data {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB else { throw SQLiteStoreError.invalid("Invalid database value") }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= maximumBytes else { throw SQLiteStoreError.invalid("Value exceeds 128 MiB limit") }
        if count == 0 { return Data() }
        guard let bytes = sqlite3_column_blob(statement, column) else { throw SQLiteStoreError.invalid("Missing database value") }
        return Data(bytes: bytes, count: count)
    }

    private func failure(_ code: Int32) -> SQLiteStoreError {
        .database(code: code, message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "Connection unavailable")
    }

    private func fileError(_ action: String) -> SQLiteStoreError {
        .invalid("\(action): \(String(cString: strerror(errno)))")
    }
}
