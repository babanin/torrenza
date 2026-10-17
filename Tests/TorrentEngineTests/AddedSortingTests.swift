import Foundation
import Testing
import TorrentCore
@testable import TorrentEngine

@Suite @MainActor struct AddedSortingTests {
    private func torrent(_ id: String, name: String, at seconds: TimeInterval?,
                         destination: String = "/Volumes/Storage") -> TransferSnapshot {
        var transfer = TransferSnapshot(
            id: id, name: name, destination: URL(fileURLWithPath: destination), isMultiFile: true,
            files: [
                .init(file: .init(index: 0, path: [name, "nested", "movie.mp4"], length: 10, offset: 0), selected: true),
                .init(file: .init(index: 1, path: [name, "readme.txt"], length: 10, offset: 10), selected: false)
            ])
        transfer.addedAt = seconds.map { Date(timeIntervalSince1970: $0) }
        return transfer
    }

    @Test func chronologicalOrderingKeepsUnknownLastInBothDirections() {
        let snapshots = [
            torrent("new", name: "A newest", at: 2_000),
            torrent("unknown", name: "A unknown", at: nil),
            torrent("old", name: "Z oldest", at: 1_000)
        ]
        let model = TorrentTreeModel()
        model.update(snapshots, sort: .init(column: .added, ascending: true))
        let root = model.children(of: nil)[0]
        #expect(model.children(of: root).map(\.id) == ["torrent:old", "torrent:new", "torrent:unknown"])
        model.update(snapshots, sort: .init(column: .added, ascending: false))
        #expect(model.children(of: root).map(\.id) == ["torrent:new", "torrent:old", "torrent:unknown"])
    }

    @Test func EqualDatesUseNaturalNameAndIdentityTieBreaks() {
        let snapshots = [
            torrent("z", name: "item2", at: 100),
            torrent("a", name: "item2", at: 100),
            torrent("b", name: "item10", at: 100)
        ]
        let model = TorrentTreeModel()
        for ascending in [true, false] {
            model.update(snapshots, sort: .init(column: .added, ascending: ascending))
            #expect(model.children(of: model.roots[0]).map(\.id) == ["torrent:a", "torrent:z", "torrent:b"])
        }
    }

    @Test func groupsUseLatestTorrentAndContentInheritsTorrentDate() {
        let snapshots = [
            torrent("old", name: "Old", at: 100, destination: "/Volumes/Storage/first"),
            torrent("new", name: "New", at: 300, destination: "/Volumes/Storage/first"),
            torrent("unknown", name: "Unknown", at: nil, destination: "/Volumes/Storage/first"),
            torrent("middle", name: "Middle", at: 200, destination: "/Volumes/Storage/second"),
            torrent("other", name: "Other", at: 150, destination: "/Volumes/Other")
        ]
        let model = TorrentTreeModel()
        model.update(snapshots, sort: .init(column: .added, ascending: false))
        let roots = model.children(of: nil)
        #expect(roots.map(\.name) == ["Storage", "Other"])
        #expect(model.addedAt(for: roots[0]) == Date(timeIntervalSince1970: 300))
        let locations = model.children(of: roots[0])
        #expect(locations.map(\.name) == ["first", "second"])
        #expect(model.addedAt(for: locations[0]) == Date(timeIntervalSince1970: 300))
        let newest = model.children(of: locations[0])[0]
        #expect(newest.name == "New")
        let contents = model.children(of: newest)
        #expect(contents.map(\.name) == ["nested", "readme.txt"])
        for node in [newest] + contents + model.children(of: contents[0]) {
            #expect(model.addedAt(for: node) == Date(timeIntervalSince1970: 300))
        }
        let unknown = model.children(of: locations[0])[2]
        #expect(model.addedAt(for: unknown) == nil)
        #expect(model.addedAt(for: model.children(of: unknown)[0]) == nil)
    }

    @Test func searchRetainsHierarchyAndResortsRepresentedDescendants() {
        var newest = torrent("new", name: "New", at: 300, destination: "/Volumes/Storage/first")
        newest.files = [.init(file: .init(index: 0, path: ["New", "other.bin"], length: 10, offset: 0), selected: true)]
        let snapshots = [
            torrent("old", name: "Old", at: 100, destination: "/Volumes/Storage/first"), newest,
            torrent("middle", name: "Middle", at: 200, destination: "/Volumes/Storage/second")
        ]
        let model = TorrentTreeModel(), order = TreeSortOrder(column: .added, ascending: false)
        model.update(snapshots, sort: order)
        #expect(model.children(of: model.roots[0]).map(\.name) == ["first", "second"])
        model.update(snapshots, search: "movie", sort: order)
        let locations = model.children(of: model.roots[0])
        #expect(locations.map(\.name) == ["second", "first"])
        #expect(model.addedAt(for: model.roots[0]) == Date(timeIntervalSince1970: 200))
        let oldest = model.children(of: locations[1])[0]
        #expect(oldest.name == "Old")
        #expect(model.children(of: oldest).map(\.name) == ["nested"])
        #expect(model.children(of: model.children(of: oldest)[0]).map(\.name) == ["movie.mp4"])
    }

    @Test func dateUpdatesReorderCachedSiblingsWithoutReplacingNodes() {
        var old = torrent("a", name: "A", at: nil)
        let recent = torrent("b", name: "B", at: 200)
        let model = TorrentTreeModel(), order = TreeSortOrder(column: .added, ascending: true)
        model.update([old, recent], sort: order)
        let root = model.children(of: nil)[0]
        let before = model.children(of: root)
        #expect(before.map(\.name) == ["B", "A"])
        old.addedAt = Date(timeIntervalSince1970: 100)
        #expect(model.update([old, recent], sort: order))
        let after = model.children(of: root)
        #expect(after.map(\.name) == ["A", "B"])
        #expect(after[0] === before[1])
        #expect(model.roots[0] === root)
        #expect(!model.update([old, recent], sort: order))
    }
}
