#if DEBUG
import CryptoKit
import Foundation
import TorrentCore
import TorrentEngine

@MainActor extension AppModel {
    /// Covers failed Add Torrent actions and retry using a disposable profile and payload.
    func runImportFailureSmoke() async throws -> [String] {
        let identifier = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Torrenza-Import-Smoke-\(identifier)", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let conflictingDestination = root.appendingPathComponent("existing", isDirectory: true)
        let cleanDestination = root.appendingPathComponent("downloads", isDirectory: true)
        let suite = "dev.torrenza.import-smoke.\(identifier)"
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(root: state, defaults: defaults)
        var lines: [String] = []
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw TorrentError.storage("Import smoke: \(message)") }
            lines.append("PASS: " + message)
        }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: conflictingDestination, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cleanDestination, withIntermediateDirectories: true)
            model.launch()
            await model.waitForProfileWork()
            try require(model.isProfileReady && model.error == nil, "Import checks open an isolated temporary AppModel profile")
            model.settings.bootstrapNodes = []
            model.saveSettings()
            await model.waitForProfileWork()

            let original = Data(repeating: 37, count: 32_768)
            let hash = Data(Insecure.SHA1.hash(data: original))
            let meta = TorrentMetainfo(infoHash: Data(Insecure.SHA1.hash(data: Data(identifier.utf8))), rawInfo: Data("de".utf8), name: "Import Fixture", pieceLength: 32_768,
                                       pieceHashes: [hash, hash], files: [
                                        TorrentFile(index: 0, path: ["Import Fixture", "first.bin"], length: 32_768, offset: 0),
                                        TorrentFile(index: 1, path: ["Import Fixture", "second.bin"], length: 32_768, offset: 32_768)
                                       ], trackerTiers: [], isPrivate: true, isMultiFile: true)
            let existingFile = conflictingDestination.appendingPathComponent("Import Fixture/first.bin")
            try FileManager.default.createDirectory(at: existingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try original.write(to: existingFile)
            let draft = ImportDraft(metainfo: meta, ratio: 100)
            draft.destination = conflictingDestination
            draft.selectedFiles = [0]
            model.pendingImport = draft
            model.finishImport(draft)
            try require(draft.isAdding, "Add Torrent marks the submitted draft as pending immediately")
            await model.waitForProfileWork()
            try require(draft.error?.contains("Refusing to overwrite existing file") == true, "Existing-file rejection is available on the open import sheet")
            try require(model.error == nil, "Import failure does not rely on an alert behind the sheet")
            try require(model.pendingImport === draft && !draft.isAdding, "Failed import keeps its sheet open and enables retry")
            try require(draft.destination == conflictingDestination && draft.selectedFiles == [0] && draft.ratio == 100 && !draft.unlimitedSeed && !draft.allowExisting,
                        "Failed import retains destination, file selection, ratio, and reuse choices")
            try require(try Data(contentsOf: existingFile) == original, "Rejected import preserves the existing file byte for byte")
            let rejectedSnapshots = await model.engine.currentSnapshots()
            try require(rejectedSnapshots.isEmpty, "Rejected import does not leave a transfer in the library")

            draft.destination = cleanDestination
            draft.sourceText = "file:///invalid-source.torrent"
            model.finishImport(draft)
            try require(draft.error == nil && draft.isAdding, "Retry clears the previous sheet error before starting")
            await model.waitForProfileWork()
            try require(draft.error?.contains("HTTP or HTTPS") == true && !draft.isAdding && model.pendingImport === draft,
                        "Invalid source errors also remain visible on the import sheet")
            try require(try FileManager.default.contentsOfDirectory(atPath: cleanDestination.path).isEmpty,
                        "Source validation failure creates no payload")

            draft.sourceText = ""
            model.finishImport(draft)
            try require(draft.error == nil && draft.isAdding, "Corrected retry clears the source error immediately")
            await model.waitForProfileWork()
            let snapshots = await model.engine.currentSnapshots()
            try require(model.pendingImport == nil && !draft.isAdding && draft.error == nil && model.error == nil,
                        "Successful retry closes the sheet without stale errors or pending state")
            try require(snapshots.count == 1 && snapshots.first?.id == meta.id && snapshots.first?.files.map(\.selected) == [true, false],
                        "Successful retry adds exactly one transfer with the preserved file selection")
            try require(FileManager.default.fileExists(atPath: cleanDestination.appendingPathComponent("Import Fixture/first.bin").path)
                        && !FileManager.default.fileExists(atPath: cleanDestination.appendingPathComponent("Import Fixture/second.bin").path),
                        "Successful retry creates only the selected payload")

            let duplicate = ImportDraft(metainfo: meta, ratio: 100)
            duplicate.destination = cleanDestination
            duplicate.selectedFiles = [0]
            model.pendingImport = duplicate
            model.finishImport(duplicate)
            await model.waitForProfileWork()
            try require(duplicate.error?.contains("already in your library") == true && !duplicate.isAdding && model.pendingImport === duplicate && model.error == nil,
                        "Duplicate-torrent rejection remains actionable in the sheet")
            let afterDuplicate = await model.engine.currentSnapshots()
            try require(afterDuplicate.count == 1 && afterDuplicate.first?.id == meta.id,
                        "Duplicate rejection preserves the successfully imported transfer")
            model.pendingImport = nil
            await model.shutdown()
            return lines
        } catch {
            await model.shutdown()
            throw error
        }
    }
}
#endif
