import Foundation
import Testing
import TorrentCore
@testable import TorrentEngine

@Suite @MainActor struct TreeTests {
    private func torrent(_ id: String = "a", name: String = "A", destination: String = "/Volumes/Storage/torrents/other", state: TransferState = .downloading) -> TransferSnapshot {
        TransferSnapshot(id: id, name: name, destination: URL(fileURLWithPath: destination), isMultiFile: true, state: state,
            files: [.init(file: .init(index: 0, path: [name, "nested", "movie.mp4"], length: 100, offset: 0), selected: true, verifiedBytes: 40), .init(file: .init(index: 1, path: [name, "readme.txt"], length: 50, offset: 100), selected: false)], completedBytes: 40, selectedBytes: 100, downloadRate: 20)
    }
    @Test func actualPathsAndSharedAncestors() {
        let model = TorrentTreeModel()
        #expect(model.update([torrent(), torrent("b", name: "B", destination: "/Volumes/Storage/torrents/video")]))
        #expect(model.roots.map(\.name) == ["Storage"])
        let torrents = model.roots[0].children[0]
        #expect(torrents.name == "torrents")
        #expect(torrents.children.map(\.name) == ["other", "video"])
        let a = torrents.children[0].children[0]
        #expect(a.name == "A")
        #expect(a.url?.path == "/Volumes/Storage/torrents/other/A")
        #expect(a.children.map(\.name) == ["nested", "readme.txt"])
        #expect(a.children[0].children[0].url?.path == "/Volumes/Storage/torrents/other/A/nested/movie.mp4")
        #expect(torrents.transferIDs == ["a", "b"])
        #expect(model.metrics(for: torrents).size == 200)
        #expect(model.metrics(for: torrents).verified == 80)
        #expect(model.metrics(for: torrents).downloadRate == 40)
    }
    @Test func progressUpdatesRetainNodes() {
        let model = TorrentTreeModel(); var transfer = torrent()
        model.update([transfer]); let root = model.roots[0]
        transfer.completedBytes = 90; transfer.downloadRate = 22; transfer.files[0].verifiedBytes = 90
        #expect(!model.update([transfer]))
        #expect(model.roots[0] === root)
        #expect(model.metrics(for: root).verified == 90)
        let contentFolder = root.children[0].children[0].children[0].children[0]
        #expect(model.metrics(for: contentFolder).verified == 90)
    }
    @Test func singleFileHasNoWrapper() {
        let model = TorrentTreeModel()
        model.update([TransferSnapshot(id: "one", name: "single.iso", destination: URL(fileURLWithPath: "/Volumes/External"), files: [.init(file: .init(index: 0, path: ["single.iso"], length: 42, offset: 0), selected: true)], selectedBytes: 42)])
        let file = model.roots[0].children[0]
        #expect(file.url?.path == "/Volumes/External/single.iso")
        #expect(!file.expandable)
        #expect(file.children.isEmpty)
    }
    @Test func searchAndFiltersRetainAncestors() {
        let model = TorrentTreeModel()
        model.update([torrent(), torrent("b", name: "B", destination: "/Volumes/Other", state: .paused)], search: "movie", filter: .active)
        #expect(model.roots.count == 1)
        let a = model.roots[0].children[0].children[0].children[0]
        #expect(a.children.map(\.name) == ["nested"])
        #expect(a.children[0].children[0].name == "movie.mp4")
        model.update([torrent(state: .unavailable)], filter: .attention)
        #expect(model.roots[0].name == "Storage")
    }
    @Test func largeMetadataTreeIsLazyAndStable() {
        var transfer = torrent()
        transfer.files = (0..<10_000).map { .init(file: .init(index: $0, path: ["A", "folder\($0 / 100)", "file\($0).bin"], length: 8, offset: Int64($0 * 8)), selected: true) }
        transfer.selectedBytes = 80_000
        let model = TorrentTreeModel(); model.update([transfer])
        let a = model.roots[0].children[0].children[0].children[0]
        #expect(a.children.count == 100)
        #expect(a.children[0].children.count == 100)
        #expect(model.metrics(for: a.children[0]).size == 800)
        #expect(!model.update([transfer]))
    }
    @Test func sparseFileLookupUsesCurrentProgressWithoutRebuilding() {
        let model = TorrentTreeModel()
        var transfer = torrent()
        transfer.files = [
            .init(file: .init(index: 3, path: ["A", "folder", "one"], length: 100, offset: 0), selected: true),
            .init(file: .init(index: 19, path: ["A", "folder", "two"], length: 50, offset: 100), selected: true)
        ]
        model.update([transfer])
        let generation = model.generation
        #expect(model.file(transferID: transfer.id, index: 0) == nil)
        #expect(model.file(transferID: transfer.id, index: 19)?.file.length == 50)
        transfer.files[1].verifiedBytes = 40
        #expect(!model.update([transfer]))
        #expect(model.generation == generation)
        #expect(model.file(transferID: transfer.id, index: 19)?.verifiedBytes == 40)
        let folder = model.roots[0].children[0].children[0].children[0].children[0]
        #expect(model.metrics(for: folder).verified == 40)
        #expect(model.metrics(for: folder).size == 150)
    }

    @Test func resolvingAndPadding() {
        let model = TorrentTreeModel()
        var transfer = torrent()
        transfer.files.append(.init(file: .init(index: 2, path: ["A", ".pad", "42"], length: 42, offset: 150, isPadding: true), selected: false))
        model.update([transfer, .init(id: "resolving", name: "Magnet", state: .resolving)])
        #expect(model.roots.first?.name == "Resolving Metadata")
        #expect(model.roots[1].children[0].children[0].children[0].children.count == 2)
    }
}
