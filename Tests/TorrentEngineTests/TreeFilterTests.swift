import Foundation
import Testing
import TorrentCore
@testable import TorrentEngine

/// The tree and the sidebar counts share one predicate; these semantics are load-bearing.
@Suite @MainActor struct TreeFilterTests {
    private func transfer(_ state: TransferState) -> TransferSnapshot {
        TransferSnapshot(id: state.rawValue, name: state.rawValue, destination: URL(fileURLWithPath: "/Volumes/Storage"), state: state)
    }

    @Test func everyStatePrefersExactlyOnePrimaryFilter() {
        for state in TransferState.allCases {
            let matches = TreeFilter.allCases.filter { $0.matches(transfer(state)) }
            #expect(matches.contains(.all))
            switch state {
            case .downloading, .checking, .resolving, .seeding:
                #expect(matches.contains(.active))
                #expect(!matches.contains(.paused))
            case .queued:
                #expect(matches.contains(.downloading))
                #expect(!matches.contains(.active))
            case .paused, .completed:
                #expect(!matches.contains(.active))
            case .unavailable, .failed:
                #expect(matches.contains(.attention))
            }
        }
    }

    @Test func completedContainsSeedingAndCompleted() {
        #expect(TreeFilter.completed.matches(transfer(.completed)))
        #expect(TreeFilter.completed.matches(transfer(.seeding)))
        #expect(!TreeFilter.completed.matches(transfer(.downloading)))
        #expect(!TreeFilter.completed.matches(transfer(.paused)))
    }

    @Test func attentionSelectsFailuresAndUnavailableVolumes() {
        #expect(TreeFilter.attention.matches(transfer(.failed)))
        #expect(TreeFilter.attention.matches(transfer(.unavailable)))
        #expect(!TreeFilter.attention.matches(transfer(.paused)))
        #expect(!TreeFilter.attention.matches(transfer(.seeding)))
    }

    @Test func pausedMatchesOnlyPaused() {
        for state in TransferState.allCases {
            #expect(TreeFilter.paused.matches(transfer(state)) == (state == .paused))
        }
    }

    @Test func treeFilteringUsesTheSharedPredicate() {
        let model = TorrentTreeModel()
        let states: [TransferState] = [.downloading, .seeding, .paused, .failed]
        let snapshots = states.map(transfer)
        model.update(snapshots, filter: .attention)
        let shown = model.roots.flatMap { $0.transferIDs }
        let expected = snapshots.filter { TreeFilter.attention.matches($0) }.map(\.id)
        #expect(Set(shown) == Set(expected))
    }
}
