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
    @Test func uploadedTotalsPreserveHistoryAndSkippedFiles() {
        let model = TorrentTreeModel()
        var transfer = torrent()
        transfer.uploadedBytes = 900
        transfer.fileUploadHistoryComplete = false
        transfer.files[0].uploadedBytes = 120
        transfer.files[1].uploadedBytes = 30
        model.update([transfer])
        let root = model.roots[0]
        let torrentNode = root.children[0].children[0].children[0]
        let folder = torrentNode.children[0]
        let skippedFile = torrentNode.children[1]
        #expect(model.metrics(for: root).uploadedBytes == 900)
        #expect(model.metrics(for: torrentNode).uploadHistoryComplete)
        #expect(model.metrics(for: folder).uploadedBytes == 120)
        #expect(!model.metrics(for: folder).uploadHistoryComplete)
        #expect(model.metrics(for: skippedFile).uploadedBytes == 30)
        #expect(model.metrics(for: skippedFile).size == 0)
        transfer.files[0].uploadedBytes = 180
        transfer.uploadedBytes = 960
        #expect(!model.update([transfer]))
        #expect(model.metrics(for: folder).uploadedBytes == 180)
        #expect(model.metrics(for: root).uploadedBytes == 960)
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

    @Test func sizeSortStaysWithinEachFolderAndIncludesSkippedFileLength() {
        var a = torrent(destination: "/Volumes/Storage")
        a.files = [
            .init(file: .init(index: 0, path: ["A", "folder", "huge.bin"], length: 2_000_000, offset: 0), selected: true),
            .init(file: .init(index: 1, path: ["A", "folder", "tiny.bin"], length: 90, offset: 2_000_000), selected: true),
            .init(file: .init(index: 2, path: ["A", "skipped.bin"], length: 900_000, offset: 2_000_090), selected: false),
            .init(file: .init(index: 3, path: ["A", "small.bin"], length: 12_000, offset: 2_900_090), selected: true)
        ]
        a.selectedBytes = 2_012_090
        let model = TorrentTreeModel()
        model.update([a, torrent("b", name: "B", destination: "/Volumes/Storage")], sort: .init(column: .size, ascending: true))
        let root = model.children(of: nil)[0]
        let torrents = model.children(of: root)
        #expect(torrents.map(\.name) == ["B", "A"])
        let children = model.children(of: torrents[1])
        #expect(children.map(\.name) == ["small.bin", "skipped.bin", "folder"])
        #expect(model.children(of: children[2]).map(\.name) == ["tiny.bin", "huge.bin"])
        #expect(model.update([a, torrent("b", name: "B", destination: "/Volumes/Storage")], sort: .init(column: .size, ascending: false)))
        #expect(model.children(of: torrents[1]).map(\.name) == ["folder", "skipped.bin", "small.bin"])
        #expect(model.children(of: children[2]).map(\.name) == ["huge.bin", "tiny.bin"])
    }

    @Test func dynamicUploadedSortRetainsIdentityAndOnlyAdvancesOnReorder() {
        var transfer = torrent(destination: "/Volumes/Storage")
        transfer.files[0].uploadedBytes = 2_000_000
        transfer.files[1].uploadedBytes = 900_000
        let model = TorrentTreeModel(), order = TreeSortOrder(column: .uploaded, ascending: false)
        model.update([transfer], sort: order)
        let root = model.children(of: nil)[0], torrentNode = model.children(of: root)[0]
        let initial = model.children(of: torrentNode), generation = model.generation
        #expect(initial.map(\.name) == ["nested", "readme.txt"])
        transfer.files[0].uploadedBytes += 10
        #expect(!model.update([transfer], sort: order))
        #expect(model.generation == generation)
        transfer.files[1].uploadedBytes = 3_000_000
        #expect(model.update([transfer], sort: order))
        #expect(model.generation == generation + 1)
        let reordered = model.children(of: torrentNode)
        #expect(reordered[0] === initial[1])
        #expect(reordered[1] === initial[0])
        #expect(model.children(of: nil)[0] === root)
    }

    @Test func numericTiesUseNaturalNamesThenIDsAndMissingValuesStayLast() {
        let snapshots = [torrent("z", name: "item2", destination: "/Volumes/Storage"),
                         torrent("a", name: "item2", destination: "/Volumes/Storage"),
                         torrent("b", name: "item10", destination: "/Volumes/Storage"),
                         torrent("c", name: "nested", destination: "/Volumes/Storage/aaa")]
        let model = TorrentTreeModel()
        for ascending in [true, false] {
            model.update(snapshots, sort: .init(column: .seeds, ascending: ascending))
            #expect(model.children(of: model.children(of: nil)[0]).map(\.id) == ["torrent:a", "torrent:z", "torrent:b", "folder:/Volumes/Storage/aaa"])
        }
        model.update(snapshots, sort: .init(column: .name, ascending: false))
        #expect(model.children(of: model.children(of: nil)[0]).map(\.name) == ["item10", "item2", "item2", "aaa"])
        model.update(snapshots)
        #expect(model.children(of: model.children(of: nil)[0]).first?.name == "aaa")
    }

    @Test func progressSortUsesFractionsAndPlacesSkippedFilesLast() {
        var transfer = torrent(destination: "/Volumes/Storage")
        transfer.files = [
            .init(file: .init(index: 0, path: ["A", "large"], length: 1_000, offset: 0), selected: true, verifiedBytes: 100),
            .init(file: .init(index: 1, path: ["A", "small"], length: 10, offset: 1_000), selected: true, verifiedBytes: 9),
            .init(file: .init(index: 2, path: ["A", "skipped"], length: 100, offset: 1_010), selected: false)
        ]
        let model = TorrentTreeModel()
        model.update([transfer], sort: .init(column: .progress, ascending: true))
        let node = model.children(of: model.children(of: nil)[0])[0]
        #expect(model.children(of: node).map(\.name) == ["large", "small", "skipped"])
        model.update([transfer], sort: .init(column: .progress, ascending: false))
        #expect(model.children(of: node).map(\.name) == ["small", "large", "skipped"])
    }

    @Test(arguments: [TreeSortColumn.size, .progress, .download, .upload, .uploaded, .seeds, .peers])
    func numericColumnsFollowLiveValues(column: TreeSortColumn) {
        func setValue(_ transfer: inout TransferSnapshot, _ value: Int64) {
            switch column {
            case .size: transfer.selectedBytes = value
            case .progress: transfer.selectedBytes = 100; transfer.completedBytes = value
            case .download: transfer.downloadRate = Double(value)
            case .upload: transfer.uploadRate = Double(value)
            case .uploaded: transfer.uploadedBytes = 9_007_199_254_740_992 + value
            case .seeds: transfer.swarm.connectedSeeds = Int(value); transfer.swarm.reportedSeeds = Int(100 - value)
            case .peers: transfer.swarm.connectedPeers = Int(value); transfer.swarm.reportedPeers = Int(100 - value)
            case .name: break
            }
        }
        var a = torrent("a", name: "A", destination: "/Volumes/Storage")
        var b = torrent("b", name: "B", destination: "/Volumes/Storage")
        setValue(&a, 11); setValue(&b, 12)
        let model = TorrentTreeModel(), order = TreeSortOrder(column: column, ascending: true)
        model.update([a, b], sort: order)
        let root = model.children(of: nil)[0]
        let nodes = model.children(of: root)
        #expect(nodes.map(\.name) == ["A", "B"])
        setValue(&a, 13)
        #expect(model.update([a, b], sort: order))
        #expect(model.children(of: root).map(\.name) == ["B", "A"])
        #expect(model.children(of: root)[1] === nodes[0])
        #expect(model.update([a, b], sort: .init(column: column, ascending: false)))
        #expect(model.children(of: root).map(\.name) == ["A", "B"])
        model.update([a, b], sort: order)
        #expect(model.update([a, b]))
        #expect(model.children(of: root).map(\.name) == ["A", "B"])
    }

    @Test func sortingDoesNotMaterializeDescendantsAndSearchReplacesCaches() {
        let model = TorrentTreeModel()
        var descendantsCreated = 0
        let child = TorrentTreeNode(id: "child", name: "child", url: nil, kind: .folder, transferIDs: ["a"], expandable: true) {
            descendantsCreated += 1
            return []
        }
        let parent = TorrentTreeNode(id: "parent", name: "parent", url: nil, kind: .folder, transferIDs: ["a"], expandable: true) { [child] }
        var transfer = torrent(destination: "/Volumes/Storage")
        let order = TreeSortOrder(column: .uploaded, ascending: true)
        model.update([transfer], sort: order)
        #expect(model.children(of: parent)[0] === child)
        transfer.uploadedBytes += 10
        model.update([transfer], sort: order)
        model.update([transfer], sort: .init(column: .name, ascending: false))
        #expect(descendantsCreated == 0)
        let oldRoot = model.children(of: nil)[0]
        model.update([transfer], search: "movie", filter: .active, sort: order)
        let newRoot = model.children(of: nil)[0]
        #expect(newRoot !== oldRoot)
        let node = model.children(of: newRoot)[0]
        #expect(model.children(of: node).map(\.name) == ["nested"])
        model.update([transfer], filter: .paused, sort: order)
        #expect(model.children(of: nil).isEmpty)
    }
}
