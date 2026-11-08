import Foundation
import Testing
import TorrentCore
@testable import TorrentEngine

@Suite @MainActor struct TreeActionTests {
    private func torrent(_ id: String = "a") -> TransferSnapshot {
        TransferSnapshot(id: id, name: "Archive", destination: URL(fileURLWithPath: "/Volumes/Test"), isMultiFile: true,
                         files: [
                            .init(file: .init(index: 0, path: ["Archive", "nested", "visible.bin"], length: 10, offset: 0), selected: true),
                            .init(file: .init(index: 2, path: ["Archive", "nested", "hidden.bin"], length: 10, offset: 10), selected: false),
                            .init(file: .init(index: 3, path: ["Archive", "nested-other", "other.bin"], length: 10, offset: 20), selected: false),
                            .init(file: .init(index: 4, path: ["Archive", "nested", ".pad"], length: 10, offset: 30, isPadding: true), selected: false)
                         ])
    }

    @Test func hiddenDescendantsUseCompleteMetadataAndComponentBoundaries() throws {
        let transfer = torrent(), model = TorrentTreeModel()
        model.update([transfer], search: "visible")
        let folder = try #require(model.roots.first?.children.first?.children.first)
        #expect(folder.id == "contents:a:nested")
        #expect(folder.fileIndices == [0])
        let selection = try #require(TorrentTreeActions.fileSelection(for: folder, transfers: [transfer]))
        #expect(selection.id == "a")
        #expect(selection.indices == [0, 2])
        #expect(TorrentTreeActions.resolve([folder], transfers: [transfer]) == ["a": .files([0, 2])])
    }

    @Test func overlappingSelectionsDeduplicateAndWholeTorrentWinsInEitherOrder() throws {
        let transfer = torrent(), model = TorrentTreeModel()
        model.update([transfer])
        let torrentNode = try #require(model.roots.first?.children.first)
        let folder = try #require(torrentNode.children.first { $0.name == "nested" })
        let file = try #require(folder.children.first)
        #expect(TorrentTreeActions.resolve([folder, file, folder], transfers: [transfer]) == ["a": .files([0, 2])])
        for nodes in [[torrentNode, folder, file], [folder, file, torrentNode]] {
            #expect(TorrentTreeActions.resolve(nodes, transfers: [transfer]) == ["a": .torrent])
        }
        #expect(TorrentTreeActions.fileSelection(for: torrentNode, transfers: [transfer]) == nil)
    }

    @Test func differentTorrentsAndSingleFileRowsKeepIndependentTargets() throws {
        let first = torrent(), second = torrent("b")
        let single = TransferSnapshot(id: "single", name: "single.bin", destination: URL(fileURLWithPath: "/Volumes/Test"),
                                      files: [.init(file: .init(index: 7, path: ["single.bin"], length: 10, offset: 0), selected: false)])
        let transfers = [first, second, single], model = TorrentTreeModel()
        model.update(transfers)
        let root = try #require(model.roots.first)
        let firstNode = try #require(root.children.first { $0.id == "torrent:a" })
        let secondNode = try #require(root.children.first { $0.id == "torrent:b" })
        let singleNode = try #require(root.children.first { $0.id == "torrent:single" })
        let folder = try #require(firstNode.children.first { $0.name == "nested" })
        #expect(TorrentTreeActions.resolve([folder, secondNode, singleNode], transfers: transfers) == ["a": .files([0, 2]), "b": .torrent, "single": .files([7])])
        #expect(TorrentTreeActions.resolve([singleNode, root], transfers: transfers) == ["a": .torrent, "b": .torrent, "single": .torrent])
        #expect(TorrentTreeActions.fileSelection(for: root, transfers: transfers) == nil)
    }

    @Test func locationFolderUsesWholeTorrentScopeAndStaleFileCannotWidenScope() {
        let transfer = torrent()
        let location = TorrentTreeNode(id: "folder:/Volumes/Test", name: "Test", url: nil, kind: .folder, transferIDs: ["a"], expandable: true)
        let stale = TorrentTreeNode(id: "file:a:99", name: "gone", url: nil, kind: .file("a", 99), transferIDs: ["a"], expandable: false)
        let staleFolder = TorrentTreeNode(id: "contents:a:gone", name: "gone", url: nil, kind: .folder, transferIDs: ["a"], expandable: true)
        #expect(TorrentTreeActions.resolve([location], transfers: [transfer]) == ["a": .torrent])
        #expect(TorrentTreeActions.fileSelection(for: location, transfers: [transfer]) == nil)
        #expect(TorrentTreeActions.resolve([stale, staleFolder], transfers: [transfer]).isEmpty)
        #expect(TorrentTreeActions.resolve([location], transfers: []).isEmpty)
    }
    @Test func indexedSelectionMatchesCompleteMetadataWithSparseIndices() throws {
        let transfer = torrent(), model = TorrentTreeModel()
        model.update([transfer], search: "visible")
        let folder = try #require(model.roots.first?.children.first?.children.first)
        let index = TorrentTreeSelectionIndex(transfers: [transfer])
        #expect(index.fileSelection(for: folder)?.indices == [0, 2])
        #expect(index.state(for: folder) == .mixed)
        let visible = try #require(folder.children.first)
        #expect(index.state(for: visible) == .on)
        let padding = TorrentTreeNode(id: "file:a:4", name: ".pad", url: nil, kind: .file("a", 4), transferIDs: ["a"], expandable: false)
        let stale = TorrentTreeNode(id: "file:a:99", name: "gone", url: nil, kind: .file("a", 99), transferIDs: ["a"], expandable: false)
        #expect(index.state(for: padding) == nil)
        #expect(index.state(for: stale) == nil)
    }

    @Test func projectedSelectionIsScopedToSnapshotAndPendingOverrides() throws {
        var transfer = torrent()
        let model = TorrentTreeModel()
        model.update([transfer])
        let folder = try #require(model.roots.first?.children.first?.children.first { $0.name == "nested" })
        let original = TorrentTreeSelectionIndex(transfers: [transfer])
        let pending = TorrentTreeSelectionIndex(transfers: [transfer], overrides: ["a": [0: false, 2: false, 4: true, 99: true]])
        #expect(original.state(for: folder) == .mixed)
        #expect(pending.state(for: folder) == .off)
        #expect(pending.fileSelection(for: folder)?.indices == [0, 2])
        // Failed operations discard the projection; successful ones use new snapshots.
        #expect(TorrentTreeSelectionIndex(transfers: [transfer]).state(for: folder) == .mixed)
        transfer.files[1].selected = true
        #expect(TorrentTreeSelectionIndex(transfers: [transfer]).state(for: folder) == .on)
        #expect(original.state(for: folder) == .mixed)
        #expect(TorrentTreeSelectionIndex(transfers: []).state(for: folder) == nil)
    }

}
