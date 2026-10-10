import Foundation
import Testing
@testable import TorrentCore

@Suite struct SettingsTests {
    @Test func legacySettingsReceiveNewDefaults() throws {
        let settings = try JSONDecoder().decode(EngineSettings.self, from: Data("{\"maxDownloads\":2,\"storageProfile\":\"hdd\"}".utf8))
        #expect(settings.destinationProfiles.isEmpty)
        #expect(settings.maxPeers == 60)
        #expect(settings.downloadRequestWindow == 8)
        #expect(settings.payloadBudget == 32 * 1024 * 1024)
        #expect(settings.storageProfile == .hdd)
    }
    @Test func destinationOverridesRoundTrip() throws {
        var settings = EngineSettings()
        settings.destinationProfiles["/Volumes/Storage/torrents"] = .hdd
        #expect(try JSONDecoder().decode(EngineSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }
    @Test func decodedLimitsCannotBreakResourceBounds() throws {
        let settings = try JSONDecoder().decode(EngineSettings.self, from: Data("{\"maxDownloads\":-1,\"maxSeeds\":999,\"maxPeers\":999999,\"payloadBudget\":9999999999,\"downloadRequestWindow\":999,\"uploadLimit\":-2}".utf8))
        #expect(settings.maxDownloads == 1)
        #expect(settings.maxSeeds == 16)
        #expect(settings.maxPeers == 1_000)
        #expect(settings.payloadBudget == 256 * 1024 * 1024)
        #expect(settings.downloadRequestWindow == 128)
        #expect(settings.uploadLimit == 0)
    }
    @Test func highThroughputRoundTripsWithoutChangingTransferPolicy() throws {
        var settings = EngineSettings()
        settings.downloadLimit = 123_456
        settings.uploadLimit = 789
        settings.maxDownloads = 3
        settings.maxSeeds = 4
        settings.storageProfile = .hdd
        settings.destinationProfiles["/Volumes/Downloads"] = .ssd
        settings.preventIdleSleep = true
        let original = settings
        settings.apply(.highThroughput)
        #expect(settings.maxPeers == 1_000)
        #expect(settings.payloadBudget == 256 * 1024 * 1024)
        #expect(settings.downloadRequestWindow == 128)
        #expect(settings.throughputPreset == .highThroughput)
        #expect(try JSONDecoder().decode(EngineSettings.self, from: JSONEncoder().encode(settings)) == settings)
        settings.apply(.standard)
        #expect(settings == original)
    }
    @Test func legacyCustomConnectionLimitIsRetained() throws {
        let settings = try JSONDecoder().decode(EngineSettings.self, from: Data("{\"maxPeers\":125,\"payloadBudget\":33554432}".utf8))
        #expect(settings.maxPeers == 125)
        #expect(settings.downloadRequestWindow == 8)
        #expect(settings.payloadBudget == 32 * 1024 * 1024)
        #expect(settings.throughputPreset == nil)
    }
    @Test func runtimeAndDecodedResourceBoundsAgree() throws {
        var settings = EngineSettings()
        settings.maxPeers = -1
        settings.payloadBudget = 0
        settings.downloadRequestWindow = -1
        let decoded = try JSONDecoder().decode(EngineSettings.self, from: JSONEncoder().encode(settings))
        settings.normalizeResourceLimits()
        #expect(settings == decoded)
        #expect(settings.maxPeers == 1)
        #expect(settings.payloadBudget == 32 * 1024 * 1024)
        #expect(settings.downloadRequestWindow == 1)
    }
}
