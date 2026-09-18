import Foundation
import Testing
@testable import TorrentCore

@Suite struct SettingsTests {
    @Test func legacySettingsReceiveNewDefaults() throws {
        let settings = try JSONDecoder().decode(EngineSettings.self, from: Data("{\"maxDownloads\":2,\"storageProfile\":\"hdd\"}".utf8))
        #expect(settings.destinationProfiles.isEmpty)
        #expect(settings.maxPeers == 60)
        #expect(settings.storageProfile == .hdd)
    }
    @Test func destinationOverridesRoundTrip() throws {
        var settings = EngineSettings()
        settings.destinationProfiles["/Volumes/Storage/torrents"] = .hdd
        #expect(try JSONDecoder().decode(EngineSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }
    @Test func decodedLimitsCannotBreakResourceBounds() throws {
        let settings = try JSONDecoder().decode(EngineSettings.self, from: Data("{\"maxDownloads\":-1,\"maxSeeds\":999,\"maxPeers\":999999,\"payloadBudget\":9999999999,\"uploadLimit\":-2}".utf8))
        #expect(settings.maxDownloads == 1)
        #expect(settings.maxSeeds == 16)
        #expect(settings.maxPeers == 200)
        #expect(settings.payloadBudget == 32 * 1024 * 1024)
        #expect(settings.uploadLimit == 0)
    }
}
