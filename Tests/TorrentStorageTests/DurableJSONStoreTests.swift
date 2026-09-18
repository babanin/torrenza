import Foundation
import Testing
import TorrentCore
@testable import TorrentStorage

struct DurableJSONStoreTests {
    struct Record: Codable, Sendable, Equatable { let generation: Int; let bits: Data }

    @Test func atomicRoundTripAndInterruptedTemporaryFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("torrenza-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DurableJSONStore<Record>(directory: directory)
        #expect(try await store.load() == nil)
        let first = Record(generation: 1, bits: Data([0xff, 0x80]))
        try await store.save(first)
        // An interrupted pre-rename save cannot replace the last committed checkpoint.
        try Data("truncated".utf8).write(to: directory.appendingPathComponent(".transfers.json.interrupted.tmp"))
        #expect(try await store.load() == first)
        let second = Record(generation: 2, bits: Data([0xff, 0xc0]))
        try await store.save(second)
        #expect(try await store.load() == second)
    }

    @Test func oversizedOrMalformedCheckpointsFailWithoutReplacingCommittedState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("torrenza-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DurableJSONStore<Record>(directory: directory, maximumBytes: 128)
        let record = Record(generation: 3, bits: Data([1]))
        try await store.save(record)
        await #expect(throws: TorrentError.self) { try await store.save(Record(generation: 4, bits: Data(repeating: 0, count: 1024))) }
        #expect(try await store.load() == record)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("transfers.json"))
        await #expect(throws: (any Error).self) { try await store.load() }
    }
}
