import Foundation
import Testing
@testable import TorrentStorage

struct VolumeCapabilitiesTests {
    @Test func mediumClassificationRequiresKnownPhysicalEvidence() {
        #expect(VolumeCapabilities.classify(backingMedia: ["Solid State"]) == true)
        #expect(VolumeCapabilities.classify(backingMedia: ["Solid State", "Solid State"]) == true)
        #expect(VolumeCapabilities.classify(backingMedia: ["Rotational"]) == false)
        #expect(VolumeCapabilities.classify(backingMedia: ["Solid State", "Rotational"]) == false)
        #expect(VolumeCapabilities.classify(backingMedia: []) == nil)
        #expect(VolumeCapabilities.classify(backingMedia: [nil]) == nil)
        #expect(VolumeCapabilities.classify(backingMedia: ["Solid State", nil]) == nil)
        #expect(VolumeCapabilities.classify(backingMedia: ["APFS"]) == nil)
        #expect(VolumeCapabilities.classify(backingMedia: ["USB"]) == nil)
    }

    @Test func stableUUIDSurvivesRemountAndFallbackDoesNotConflateDisks() {
        #expect(VolumeCapabilities.makeIdentity(volumeUUID: "ABCD", mountSource: "/dev/disk2s1", filesystemID: "1") == VolumeCapabilities.makeIdentity(volumeUUID: "abcd", mountSource: "/dev/disk8s1", filesystemID: "2"))
        #expect(VolumeCapabilities.makeIdentity(volumeUUID: nil, mountSource: "/dev/disk2s1", filesystemID: "1") != VolumeCapabilities.makeIdentity(volumeUUID: nil, mountSource: "/dev/disk2s1", filesystemID: "2"))
        #expect(VolumeCapabilities.makeIdentity(volumeUUID: "A", mountSource: "/dev/disk2s1", filesystemID: "1") != VolumeCapabilities.makeIdentity(volumeUUID: "B", mountSource: "/dev/disk2s1", filesystemID: "1"))
    }

    @Test func unknownAndKnownResultsAreProbedOnlyOncePerVolume() {
        let cache = VolumeMediumCache(); var probes = 0
        for _ in 0..<100 {
            #expect(cache.value(for: "logical-apfs") { probes += 1; return nil } == nil)
            #expect(cache.value(for: "ssd") { probes += 1; return true } == true)
        }
        #expect(probes == 2)
    }

    @Test func realDestinationSharesIdentityWithItsParent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("torrenza-volume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = VolumeCapabilities.inspect(destination: root)
        let parent = VolumeCapabilities.inspect(destination: root.deletingLastPathComponent())
        #expect(!actual.identity.isEmpty)
        #expect(actual == parent)
        let unavailable = VolumeCapabilities.inspect(destination: root.appendingPathComponent("missing"))
        #expect(unavailable.isSolidState == nil)
        #expect(unavailable.identity.hasPrefix("unavailable:"))
    }
}
