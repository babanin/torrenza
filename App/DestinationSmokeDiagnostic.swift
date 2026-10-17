#if DEBUG
import Foundation
import TorrentCore

@MainActor extension AppModel {
    /// Exercises remembered Add Torrent destinations using disposable profile databases.
    func runDestinationSmoke() async throws -> [String] {
        let identifier = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Torrenza-Destination-Smoke-\(identifier)", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let firstDestination = root.appendingPathComponent("first-downloads", isDirectory: true)
        let secondDestination = root.appendingPathComponent("second-downloads", isDirectory: true)
        let suite = "dev.torrenza.destination-smoke.\(identifier)"
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(root: state, defaults: defaults)
        var reopened: AppModel?
        var lines: [String] = []
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw TorrentError.storage("Destination smoke: \(message)") }
            lines.append("PASS: " + message)
        }
        func sameDirectory(_ actual: URL?, _ expected: URL) -> Bool {
            actual?.standardizedFileURL.resolvingSymlinksInPath() == expected.standardizedFileURL.resolvingSymlinksInPath()
        }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: firstDestination, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: secondDestination, withIntermediateDirectories: true)
            model.launch()
            await model.waitForProfileWork()
            try require(model.isProfileReady && model.error == nil, "Destination checks open an isolated temporary profile")
            let original = model.activeProfile!
            let meta = TorrentMetainfo(infoHash: Data(repeating: 73, count: 20), rawInfo: Data("de".utf8), name: "Destination Fixture",
                                       pieceLength: 16_384, pieceHashes: [Data(repeating: 17, count: 20)],
                                       files: [TorrentFile(index: 0, path: ["fixture.bin"], length: 16_384, offset: 0)],
                                       trackerTiers: [], isPrivate: true, isMultiFile: false)
            let initialDraft = model.makeImportDraft(metainfo: meta)
            try require(initialDraft.destination == nil, "A new profile does not invent an authorized download destination")
            model.pendingImport = initialDraft
            model.rememberDestination(firstDestination, for: initialDraft)
            try require(initialDraft.error == nil && sameDirectory(initialDraft.destination, firstDestination), "Choosing a destination updates the current Add Torrent draft")
            try require(sameDirectory(model.uiState.lastDestinationDirectory, firstDestination) && model.uiState.lastDestinationBookmark?.isEmpty == false,
                        "The selected destination is stored with its security bookmark")
            model.pendingImport = nil
            let firstRepeat = model.makeImportDraft(metainfo: meta)
            try require(sameDirectory(firstRepeat.destination, firstDestination), "The next Add Torrent draft prefills the last chosen destination")

            var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model.uiState)) as! [String: Any]
            legacy.removeValue(forKey: "lastDestinationBookmark")
            let decodedLegacy = try JSONDecoder().decode(UIState.self, from: JSONSerialization.data(withJSONObject: legacy))
            try require(decodedLegacy.lastDestinationBookmark == nil && sameDirectory(decodedLegacy.lastDestinationDirectory, firstDestination),
                        "Legacy path-only interface preferences decode without losing their saved folder")

            model.beginCreateProfile()
            model.profileName = "Separate Downloads"
            model.submitProfile()
            await model.waitForProfileWork()
            try require(model.error == nil && model.activeProfile?.name == "Separate Downloads", "Destination checks create an independent second profile")
            let second = model.activeProfile!
            try require(model.uiState.lastDestinationDirectory == nil && model.uiState.lastDestinationBookmark == nil && model.makeImportDraft(metainfo: meta).destination == nil,
                        "A new profile does not inherit another profile's destination or bookmark")
            let secondDraft = model.makeImportDraft(metainfo: meta)
            model.pendingImport = secondDraft
            model.rememberDestination(secondDestination, for: secondDraft)
            try require(secondDraft.error == nil && sameDirectory(secondDraft.destination, secondDestination), "The second profile accepts its own destination")
            model.pendingImport = nil

            model.switchProfile(original)
            await model.waitForProfileWork()
            try require(model.error == nil && model.activeProfile?.id == original.id && sameDirectory(model.makeImportDraft(metainfo: meta).destination, firstDestination),
                        "Switching profiles restores the original Add Torrent destination")
            model.switchProfile(second)
            await model.waitForProfileWork()
            try require(model.error == nil && sameDirectory(model.makeImportDraft(metainfo: meta).destination, secondDestination),
                        "Switching back restores the second profile's distinct Add Torrent destination")
            await model.shutdown()

            let restored = AppModel(root: state, defaults: defaults)
            reopened = restored
            restored.launch()
            await restored.waitForProfileWork()
            try require(restored.error == nil && restored.activeProfile?.id == second.id && restored.uiState.lastDestinationBookmark?.isEmpty == false,
                        "Relaunch restores the selected profile and destination bookmark from SQLite")
            try require(sameDirectory(restored.makeImportDraft(metainfo: meta).destination, secondDestination),
                        "Add Torrent prefills the saved destination after relaunch")
            restored.switchProfile(original)
            await restored.waitForProfileWork()
            try require(restored.error == nil && sameDirectory(restored.makeImportDraft(metainfo: meta).destination, firstDestination),
                        "The original profile's destination also survives relaunch")
            try require(try FileManager.default.contentsOfDirectory(atPath: firstDestination.path).isEmpty
                        && FileManager.default.contentsOfDirectory(atPath: secondDestination.path).isEmpty,
                        "Remembering and restoring destinations creates no download payload or sidecars")
            await restored.shutdown()
            return lines
        } catch {
            await model.shutdown()
            await reopened?.shutdown()
            throw error
        }
    }
}
#endif
