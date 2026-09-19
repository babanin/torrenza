import Foundation
import Testing
import SQLite3
@testable import TorrentStorage

struct SQLiteStoreTests {
    @Test func keysOpenFreshAndClosedConnectionsWithoutReadingValues() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SQLiteStore(url: url)
        #expect(try await store.keys(namespace: "metainfo").isEmpty)
        try await store.write([
            SQLiteEntry(namespace: "metainfo", key: "first", value: Data([1])),
            SQLiteEntry(namespace: "metainfo", key: "second", value: Data([2])),
            SQLiteEntry(namespace: "other", key: "third", value: Data([3]))
        ])
        try await store.close()
        #expect(try await store.keys(namespace: "metainfo") == ["first", "second"])
        try await store.close()
    }

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("torrenza-sqlite-\(UUID().uuidString)/Torrenza.sqlite")
    }

    private func execute(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteStoreError.database(code: result, message: String(cString: sqlite3_errmsg(database)))
        }
    }

    @Test func namespacesBlobsReopenAndSingleFileAtRest() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SQLiteStore(url: url)
        #expect(try await store.read(namespace: "missing", key: "x") == nil)
        let namespace = "settings'; DROP TABLE records; --\0emoji 🐝"
        let key = "\0key'📁"
        var source = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0) })
        let expected = source
        try await store.write([
            SQLiteEntry(namespace: namespace, key: key, value: source),
            SQLiteEntry(namespace: "resume", key: key, value: Data()),
            SQLiteEntry(namespace: "", key: "", value: Data([42]))
        ])
        source.resetBytes(in: source.indices)
        #expect(try await store.read(namespace: namespace, key: key) == expected)
        #expect(try await store.read(namespace: "resume", key: key) == Data())
        #expect(try await store.readAll(namespace: "") == ["": Data([42])])
        try await store.integrityCheck()
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(files == ["Torrenza.sqlite"])
        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        let directoryMode = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        #expect(fileMode?.intValue == 0o600)
        #expect(directoryMode?.intValue == 0o700)
        try await store.close()
        let reopened = SQLiteStore(url: url)
        #expect(try await reopened.readAll(namespace: namespace) == [key: expected])
        try await reopened.close()
    }

    @Test func multiNamespaceFailureRollsBackAllChangesAndDeletes() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SQLiteStore(url: url)
        try await store.write([SQLiteEntry(namespace: "torrents", key: "old", value: Data([1]))])
        try execute("CREATE TRIGGER injected_failure BEFORE INSERT ON records WHEN NEW.key='fail' BEGIN SELECT RAISE(ABORT,'injected storage failure'); END", at: url)
        await #expect(throws: SQLiteStoreError.self) {
            try await store.write([
                SQLiteEntry(namespace: "torrents", key: "old", value: nil),
                SQLiteEntry(namespace: "settings", key: "new", value: Data([2])),
                SQLiteEntry(namespace: "resume", key: "fail", value: Data([3]))
            ])
        }
        #expect(try await store.read(namespace: "torrents", key: "old") == Data([1]))
        #expect(try await store.readAll(namespace: "settings").isEmpty)
        try await store.close()
        #expect(try await store.read(namespace: "torrents", key: "old") == Data([1]))
        try await store.integrityCheck()
        try await store.close()
    }

    @Test func replacementIsAtomicAndUnchangedBlobsAreNotUpdated() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SQLiteStore(url: url)
        try await store.replace(namespace: "ui", values: ["same": Data([1]), "old": Data([2])])
        try await store.write([SQLiteEntry(namespace: "settings", key: "preserve", value: Data([3]))])
        try execute("CREATE TRIGGER reject_updates BEFORE UPDATE ON records BEGIN SELECT RAISE(ABORT,'unexpected update'); END", at: url)
        try await store.replace(namespace: "ui", values: ["same": Data([1]), "new": Data([4])])
        #expect(try await store.readAll(namespace: "ui") == ["same": Data([1]), "new": Data([4])])
        await #expect(throws: SQLiteStoreError.self) {
            try await store.replace(namespace: "ui", values: ["same": Data([99])])
        }
        #expect(try await store.readAll(namespace: "ui") == ["same": Data([1]), "new": Data([4])])
        try await store.replace(namespace: "ui", values: [:])
        #expect(try await store.readAll(namespace: "ui").isEmpty)
        #expect(try await store.read(namespace: "settings", key: "preserve") == Data([3]))
        try await store.close()
    }

    @Test func corruptAndFutureDatabasesArePreserved() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("Not a SQLite database".utf8)
        try corrupt.write(to: url)
        let store = SQLiteStore(url: url)
        await #expect(throws: SQLiteStoreError.self) { try await store.readAll(namespace: "torrents") }
        #expect(try Data(contentsOf: url) == corrupt)
        try FileManager.default.removeItem(at: url)
        try execute("PRAGMA user_version=99; CREATE TABLE future_data(value TEXT); INSERT INTO future_data VALUES('preserved');", at: url)
        let future = try Data(contentsOf: url)
        await #expect(throws: SQLiteStoreError.self) { try await store.readAll(namespace: "torrents") }
        #expect(try Data(contentsOf: url) == future)
    }

    @Test func rejectsUnknownSchemaAndSymbolicLinks() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try execute("CREATE TABLE unrelated(value TEXT)", at: url)
        let store = SQLiteStore(url: url)
        await #expect(throws: SQLiteStoreError.self) { try await store.readAll(namespace: "torrents") }
        let link = url.deletingLastPathComponent().appendingPathComponent("link.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        await #expect(throws: SQLiteStoreError.self) { try await SQLiteStore(url: link).readAll(namespace: "x") }
    }

    @Test func concurrentCallersSerializeSafely() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SQLiteStore(url: url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    try await store.write([SQLiteEntry(namespace: "parallel", key: String(index), value: Data([UInt8(index)]))])
                }
            }
            try await group.waitForAll()
        }
        #expect(try await store.readAll(namespace: "parallel").count == 40)
        try await store.integrityCheck()
        try await store.close()
    }
}
