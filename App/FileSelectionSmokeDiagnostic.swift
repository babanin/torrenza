#if DEBUG
import AppKit
import CryptoKit
import Foundation
import TorrentCore
import TorrentEngine

@MainActor extension AppModel {
    /// Exercises real app actions and persistence using only a disposable profile and payload.
    /// Called by the profile smoke harness; no synthetic UI engine bypass is used.
    func runFileSelectionSmoke() async throws -> [String] {
        let identifier = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Torrenza-File-Selection-\(identifier)", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let destination = root.appendingPathComponent("downloads", isDirectory: true)
        let suite = "dev.torrenza.file-selection-smoke.\(identifier)"
        let defaults = UserDefaults(suiteName: suite)!
        var models: [AppModel] = []
        var lines: [String] = []
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw TorrentError.storage("File selection smoke: \(message)") }
            lines.append("PASS: " + message)
        }
        func snapshot(_ model: AppModel, _ id: String) async throws -> TransferSnapshot {
            let snapshots = await model.engine.currentSnapshots()
            guard let transfer = snapshots.first(where: { $0.id == id }) else {
                throw TorrentError.storage("File selection smoke transfer missing")
            }
            model.transfers = snapshots
            return transfer
        }
        func waitForState(_ model: AppModel, _ id: String, _ expected: TransferState) async throws -> TransferSnapshot {
            for _ in 0..<100 {
                let value = try await snapshot(model, id)
                if value.state == expected { return value }
                if value.state == .failed { throw TorrentError.storage(value.error ?? "Fixture transfer failed") }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw TorrentError.storage("File selection smoke did not enter \(expected)")
        }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let model = AppModel(root: state, defaults: defaults)
            models.append(model)
            model.launch()
            await model.waitForProfileWork()
            try require(model.isProfileReady && model.error == nil, "File controls open an isolated temporary AppModel profile")
            model.settings.bootstrapNodes = []
            model.saveSettings()
            await model.waitForProfileWork()
            let hash = Data(Insecure.SHA1.hash(data: Data(repeating: 37, count: 32_768)))
            let meta = TorrentMetainfo(infoHash: Data(Insecure.SHA1.hash(data: Data(identifier.utf8))), rawInfo: Data("de".utf8), name: "Selection Fixture", pieceLength: 32_768,
                                       pieceHashes: [hash, hash], files: [
                                        TorrentFile(index: 0, path: ["Selection Fixture", "nested", "first.bin"], length: 32_768, offset: 0),
                                        TorrentFile(index: 1, path: ["Selection Fixture", "nested", "second.bin"], length: 32_768, offset: 32_768)
                                       ], trackerTiers: [], isPrivate: true, isMultiFile: true)
            let id = try await model.engine.add(metainfo: meta, destination: destination, selectedFiles: [], seedRatio: nil)
            let idle = try await snapshot(model, id)
            try require(idle.state == .paused && idle.files.allSatisfy { !$0.selected }, "Select None creates an idle AppModel transfer")
            try require(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty, "Select None creates no payload or sidecars")

            let torrent = TorrentTreeNode(id: "torrent:\(id)", name: meta.name, url: nil, kind: .torrent(id), transferIDs: [id], expandable: true)
            let folder = TorrentTreeNode(id: "contents:\(id):nested", name: "nested", url: nil, kind: .folder, transferIDs: [id], fileIndices: [0], expandable: true)
            let first = TorrentTreeNode(id: "file:\(id):0", name: "first.bin", url: nil, kind: .file(id, 0), transferIDs: [id], fileIndices: [0], expandable: false)
            let second = TorrentTreeNode(id: "file:\(id):1", name: "second.bin", url: nil, kind: .file(id, 1), transferIDs: [id], fileIndices: [1], expandable: false)
            model.selectedNodes = [torrent]
            model.setFile(0, selected: true, transfer: idle)
            try require(model.isFileSelectionPending(for: first), "File mutation is pending immediately at input time")
            try require(!model.canRecheckSelection && !model.canRemoveSelection && !model.canRefreshSelection && !model.canSwitchProfile, "Pending file mutation blocks Recheck, Remove, Refresh and profile changes")
            try require(model.fileSelectionState(for: first) == .on && model.isFileSelected(0, transfer: idle) && model.fileSelectionState(for: folder) == .mixed, "Tree and Files inspector share immediate selected and mixed-state projection")
            await model.waitForProfileWork()
            let downloading = try await waitForState(model, id, .downloading)
            try require(downloading.files.map(\.selected) == [true, false], "Inspector checkbox immediately starts only the enabled file")
            let firstURL = destination.appendingPathComponent("Selection Fixture/nested/first.bin")
            let secondURL = destination.appendingPathComponent("Selection Fixture/nested/second.bin")
            try require(FileManager.default.fileExists(atPath: firstURL.path) && !FileManager.default.fileExists(atPath: secondURL.path), "Enabling one file creates only its payload")

            // Reuse the deliberately stale import snapshot: mutations must resolve against engine state.
            model.setFile(1, selected: true, transfer: idle)
            model.selectedNodes = [first]
            model.pauseSelection()
            model.startSelection()
            model.setFile(1, selected: false, transfer: idle)
            try require(model.fileSelectionState(for: first) == .on && model.fileSelectionState(for: second) == .off && model.isFileSelected(0, transfer: idle) && !model.isFileSelected(1, transfer: idle), "Rapid inspector and Start/Pause actions share the latest pending projection")
            await model.waitForProfileWork()
            let rapid = try await waitForState(model, id, .downloading)
            try require(rapid.files.map(\.selected) == [true, false] && model.error == nil, "Rapid actions preserve order without rebuilding from stale snapshots")

            model.selectedNodes = [torrent]
            model.pauseSelection()
            await model.waitForProfileWork()
            let paused = try await snapshot(model, id)
            try require(paused.state == .paused && paused.files.map(\.selected) == [true, false], "Whole-torrent Pause retains enabled file selection")
            model.startSelection()
            model.selectedNodes = [first]
            model.pauseSelection()
            await model.waitForProfileWork()
            let none = try await snapshot(model, id)
            try require(none.state == .paused && none.files.allSatisfy { !$0.selected }, "Whole Start followed by file Pause finishes idle when the last file is disabled")
            try require(FileManager.default.fileExists(atPath: firstURL.path), "Disabling the last file retains its downloaded data")

            model.selectedNodes = [folder, first]
            model.startSelection()
            try require(model.fileSelectionState(for: folder) == .on && model.isFileSelected(1, transfer: none), "Folder actions include search-hidden descendants and deduplicate overlapping files")
            model.pauseSelection()
            // Shutdown itself must await queued selection operations, even without the debug wait helper.
            await model.shutdown()
            let restored = AppModel(root: state, defaults: defaults)
            models.append(restored)
            restored.launch()
            await restored.waitForProfileWork()
            let persisted = try await snapshot(restored, id)
            try require(persisted.state == .paused && persisted.files.allSatisfy { !$0.selected } && restored.error == nil, "Shutdown awaits queued file actions and relaunch restores the final empty idle selection")
            try require(!restored.isFileSelectionPending(for: first) && restored.canSwitchProfile, "Relaunch has no leaked pending actions or blocked profile lifecycle")

            try FileManager.default.moveItem(at: firstURL, to: root.appendingPathComponent("held-owned-file.bin"))
            restored.setFile(0, selected: true, transfer: persisted)
            await restored.waitForProfileWork()
            let failed = try await snapshot(restored, id)
            try require(restored.error != nil && failed.state == .failed && failed.error != nil, "Failed selection retains a visible storage error and quarantine")
            try require(!FileManager.default.fileExists(atPath: firstURL.path), "Enabling missing owned content does not recreate its payload")
            for item in models { await item.shutdown() }
            return lines
        } catch {
            for item in models { await item.shutdown() }
            throw error
        }
    }
}
#endif
