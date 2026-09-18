import Foundation
import Testing
@testable import TorrentStorage

struct ProfileStoreTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("torrenza-profiles-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func existingLibraryIsDefaultWithoutMovingOrChangingRecords() async throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = SQLiteStore(url: root.appendingPathComponent("Torrenza.sqlite"))
        let entries = ["torrents", "settings", "ui", "statistics", "resume", "bookmarks"].map {
            SQLiteEntry(namespace: $0, key: "legacy", value: Data($0.utf8))
        }
        try await database.write(entries)
        let legacy = root.appendingPathComponent("transfers.json")
        try Data("legacy input".utf8).write(to: legacy)
        let store = ProfileStore(root: root)
        let profiles = try await store.list()
        #expect(profiles.count == 1)
        #expect(profiles[0].id == "default")
        #expect(profiles[0].name == "Default")
        #expect(profiles[0].databaseURL == root.appendingPathComponent("Torrenza.sqlite"))
        for entry in entries {
            #expect(try await database.read(namespace: entry.namespace, key: entry.key) == entry.value)
        }
        #expect(try Data(contentsOf: legacy) == Data("legacy input".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Profiles").path))
        try await database.close()
    }

    @Test func profilesKeepSettingsUIStatisticsAndTorrentsIsolatedAcrossReopening() async throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        let original = try #require(try await store.list().first)
        let work = try await store.create(name: "  Work  ")
        #expect(work.name == "Work")
        #expect(UUID(uuidString: work.id) != nil)
        #expect(work.directory == root.appendingPathComponent("Profiles", isDirectory: true).appendingPathComponent(work.id, isDirectory: true))
        let first = SQLiteStore(url: original.databaseURL)
        let second = SQLiteStore(url: work.databaseURL)
        for namespace in ["settings", "ui", "statistics", "torrents", "resume", "bookmarks", "dht"] {
            try await first.write([SQLiteEntry(namespace: namespace, key: "same", value: Data([1]))])
            #expect(try await second.read(namespace: namespace, key: "same") == nil)
            try await second.write([SQLiteEntry(namespace: namespace, key: "same", value: Data([2]))])
            #expect(try await first.read(namespace: namespace, key: "same") == Data([1]))
            #expect(try await second.read(namespace: namespace, key: "same") == Data([2]))
        }
        try await first.close()
        try await second.close()
        let renamed = try await store.rename(profile: work, name: "Personal")
        #expect(renamed.id == work.id)
        #expect(renamed.databaseURL == work.databaseURL)
        #expect(try await ProfileStore(root: root).list() == [original, renamed])
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.directory.path) == ["Torrenza.sqlite"])
        let reopened = SQLiteStore(url: renamed.databaseURL)
        #expect(try await reopened.read(namespace: "statistics", key: "same") == Data([2]))
        try await reopened.close()
    }

    @Test func namesAreValidatedAndConcurrentDuplicateCreationIsRejected() async throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        for name in ["", " \n ", String(repeating: "a", count: 81), "A\0B", "A\nB"] {
            await #expect(throws: ProfileStoreError.self) { try await store.create(name: name) }
        }
        let created = try await withThrowingTaskGroup(of: Bool.self) { group in
            for name in ["Work", "WORK", "work", "  Work  "] {
                group.addTask {
                    do { _ = try await store.create(name: name); return true }
                    catch ProfileStoreError.duplicateName { return false }
                }
            }
            var count = 0
            for try await success in group where success { count += 1 }
            return count
        }
        #expect(created == 1)
        let profiles = try await store.list()
        #expect(profiles.count == 2)
        await #expect(throws: ProfileStoreError.self) { try await store.rename(profile: profiles[1], name: "default") }
        let renamed = try await store.rename(profile: profiles[1], name: "WORK")
        #expect(renamed.name == "WORK")
    }

    @Test func discoveryDoesNotFollowSymbolicLinksOrAdoptUnrelatedDirectories() async throws {
        let root = location()
        let external = location()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let store = ProfileStore(root: root)
        _ = try await store.list()
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let parent = root.appendingPathComponent("Profiles")
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: external)
        await #expect(throws: ProfileStoreError.self) { try await store.list() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let child = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: external)
        let incomplete = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: false)
        let unrelated = parent.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        #expect(try await store.list().count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: incomplete.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: unrelated.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
        let forged = ProfileDescriptor(id: "default", name: "Default", directory: external)
        await #expect(throws: ProfileStoreError.self) { try await store.rename(profile: forged, name: "Changed") }
    }

    @Test func corruptProfilesRemainVisibleWithoutBlockingHealthyProfiles() async throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        let healthy = try await store.create(name: "Healthy")
        let damaged = try await store.create(name: "Damaged")
        let corrupt = Data("damaged database".utf8)
        try corrupt.write(to: root.appendingPathComponent("Torrenza.sqlite"))
        try corrupt.write(to: damaged.databaseURL)
        let profiles = try await store.list()
        #expect(profiles.count == 3)
        #expect(profiles.first?.id == "default")
        #expect(profiles.first?.name == "Default")
        #expect(profiles.contains(healthy))
        #expect(profiles.first(where: { $0.id == damaged.id })?.name == "Profile \(damaged.id.prefix(8))")
        #expect(try Data(contentsOf: root.appendingPathComponent("Torrenza.sqlite")) == corrupt)
        #expect(try Data(contentsOf: damaged.databaseURL) == corrupt)
        let next = try await store.create(name: "Another")
        #expect(try await store.list().contains(next))
    }

    @Test func corruptMetadataIsNotRewrittenDuringDiscovery() async throws {
        let root = location()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(root: root)
        let profile = try await store.create(name: "Original")
        let database = SQLiteStore(url: profile.databaseURL)
        let invalidMetadata = Data("invalid metadata".utf8)
        try await database.write([SQLiteEntry(namespace: "profile", key: "metadata", value: invalidMetadata)])
        #expect(try await store.list().count == 2)
        #expect(try await database.read(namespace: "profile", key: "metadata") == invalidMetadata)
        try await database.close()
    }

}
