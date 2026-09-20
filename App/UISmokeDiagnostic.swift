#if DEBUG
import AppKit
import Foundation
import SwiftUI
import TorrentCore
import TorrentEngine
import TorrentStorage

/// Explicit developer launch option. It does not start the engine or persist fixtures.
@MainActor extension AppModel {
    func installDebugFixture() {
        didLoadUIState = true
        let arguments = ProcessInfo.processInfo.arguments
        let longProfile = arguments.contains("--ui-long-profile")
        let fileBadges = arguments.contains("--ui-file-badges")
        let qbImport = arguments.contains("--ui-qb-import")
        let multiselect = arguments.contains("--ui-multiselect-check")
        let fixtureName = longProfile ? String(repeating: "Research ", count: 9).prefix(80).description : "Research"
        let fixtureProfile = ProfileDescriptor(id: "ui-research", name: fixtureName, directory: FileManager.default.temporaryDirectory.appendingPathComponent("Torrenza-UI/Research", isDirectory: true))
        activeProfile = fixtureProfile
        profiles = [fixtureProfile]
        statistics = StatisticsSnapshot(current: .init(id: "ui-session", downloadedBytes: 1_221_000_000, uploadedBytes: 722_000_000), lifetimeDownloadedBytes: 12_500_000_000, lifetimeUploadedBytes: 9_400_000_000)
        let dark = arguments.contains("--ui-dark")
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var swarm = SwarmCounts()
        swarm.connectedSeeds = 3; swarm.connectedPeers = 11; swarm.reportedSeeds = 120; swarm.reportedPeers = 160
        swarm.reportedAt = .now; swarm.tracker = "https://tracker.example.test/announce"
        let files = [FileSnapshot(file: TorrentFile(index: 0, path: ["A", "Documents", "Guide.pdf"], length: 4_000_000, offset: 0), selected: true, verifiedBytes: 2_000_000, uploadedBytes: 120_000), FileSnapshot(file: TorrentFile(index: 1, path: ["A", "Archive.zip"], length: 46_000_000, offset: 4_000_000), selected: true, verifiedBytes: 19_000_000, uploadedBytes: 80_000)]
        transfers = [
            TransferSnapshot(id: "ui-a", name: "A", destination: URL(fileURLWithPath: "/Volumes/Storage/torrents/other"), isMultiFile: true, state: .downloading, files: files, fileUploadHistoryComplete: false, completedBytes: 21_000_000, selectedBytes: 50_000_000, downloadedBytes: 21_000_000, uploadedBytes: 2_000_000, downloadRate: 4_200_000, uploadRate: 128_000, swarm: swarm, trackers: ["https://tracker.example.test/announce"]),
            TransferSnapshot(id: "ui-b", name: "B", destination: URL(fileURLWithPath: "/Volumes/Storage/torrents/video"), isMultiFile: true, state: .seeding, files: [.init(file: .init(index: 0, path: ["B", "Movie.mp4"], length: 1_200_000_000, offset: 0), selected: true, verifiedBytes: 1_200_000_000, uploadedBytes: 720_000_000)], completedBytes: 1_200_000_000, selectedBytes: 1_200_000_000, downloadedBytes: 1_200_000_000, uploadedBytes: 720_000_000, uploadRate: 2_100_000, swarm: swarm),
            TransferSnapshot(id: "ui-offline", name: "Linux.iso", destination: URL(fileURLWithPath: "/Volumes/Backup"), state: .unavailable, selectedBytes: 4_000_000_000, error: "Connect Backup to resume this download.")
        ]
        if fileBadges {
            let destination = URL(fileURLWithPath: "/Volumes/Storage/torrents")
            let states: [TransferState] = [.downloading, .seeding, .paused, .queued, .checking, .resolving, .completed, .unavailable, .failed]
            transfers = states.enumerated().map { index, state in
                let name = "\(index + 1). \(state.rawValue.capitalized).\(index.isMultiple(of: 2) ? "avi" : "mkv")"
                let complete = state == .seeding || state == .completed
                let verifiedBytes: Int64 = complete ? 1_200_000_000 : 420_000_000
                return TransferSnapshot(
                    id: "ui-badge-\(state.rawValue)", name: name, destination: destination, state: state,
                    files: [.init(file: .init(index: 0, path: [name], length: 1_200_000_000, offset: 0), selected: true, verifiedBytes: verifiedBytes)],
                    completedBytes: verifiedBytes, selectedBytes: 1_200_000_000, downloadedBytes: verifiedBytes,
                    downloadRate: state == .downloading ? 4_200_000 : 0,
                    uploadRate: state == .seeding ? 2_100_000 : 0, swarm: swarm,
                    error: state == .failed ? "Example download error." : state == .unavailable ? "Connect Storage to resume this download." : nil
                )
            }
            transfers.append(TransferSnapshot(
                id: "ui-badge-multi", name: "Video collection", destination: destination, isMultiFile: true, state: .downloading,
                files: [.init(file: .init(index: 0, path: ["Video collection", "Plain nested video.mkv"], length: 1_200_000_000, offset: 0), selected: true, verifiedBytes: 420_000_000)],
                completedBytes: 420_000_000, selectedBytes: 1_200_000_000, downloadRate: 4_200_000, swarm: swarm
            ))
        }
        Task { @MainActor in
            var captured = false
            defer { if arguments.contains("--ui-exit") { exit(captured ? 0 : 1) } }
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApp.windows.first(where: { $0.title == "Torrenza" }), let view = window.contentView else { return }
            let narrow = arguments.contains("--ui-narrow")
            let wide = arguments.contains("--ui-wide")
            window.setContentSize(NSSize(width: narrow ? 1000 : wide ? 2000 : 1150, height: 700))
            window.makeKeyAndOrderFront(nil)
            @MainActor func findOutline(_ view: NSView) -> NSOutlineView? {
                if let outline = view as? NSOutlineView { return outline }
                for child in view.subviews { if let outline = findOutline(child) { return outline } }
                return nil
            }
            if let outline = findOutline(view) {
                outline.expandItem(nil, expandChildren: true)
                for row in 0..<outline.numberOfRows {
                    if let node = outline.item(atRow: row) as? TorrentTreeNode, node.id == (fileBadges ? "torrent:ui-badge-downloading" : "torrent:ui-a") { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); break }
                }
            }
            var multiselectResult: (passed: Bool, lines: [String]) = (true, [])
            if multiselect {
                if let outline = findOutline(view) {
                    multiselectResult = await checkDebugMultiselection(outline: outline)
                } else {
                    multiselectResult = (false, ["FAIL: Multiselection check: Torrent outline was not found"])
                }
            }
            let importChecksPassed = !qbImport || installDebugQBittorrentImport()
            try? await Task.sleep(for: .milliseconds(600))
            let contentToCapture = qbImport ? (window.attachedSheet?.contentView ?? view) : view
            let captureView = contentToCapture.superview ?? contentToCapture
            captureView.layoutSubtreeIfNeeded(); captureView.displayIfNeeded()
            guard let bitmap = captureView.bitmapImageRepForCachingDisplay(in: captureView.bounds) else { return }
            captureView.cacheDisplay(in: captureView.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Torrenza-UI", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let basename = "ui-smoke-\(dark ? "dark" : "light")\(narrow ? "-narrow" : wide ? "-wide" : "")\(longProfile ? "-long-profile" : "")\(fileBadges ? "-file-badges" : "")\(qbImport ? "-qb-import" : "")\(arguments.contains("--ui-qb-skip-verification") ? "-unchecked" : "")\(multiselect ? "-multiselect" : "")"
            let output = directory.appendingPathComponent(basename + ".png")
            try? png.write(to: output, options: .atomic)
            var geometry = ["Window content size: \(view.bounds.size)", "Profile name: \(fixtureName)", "Toolbar item count: \(window.toolbar?.items.count ?? 0)"]
            geometry.append(contentsOf: multiselectResult.lines)
            @MainActor func describe(_ node: NSView) -> String {
                "frame: \(node.convert(node.bounds, to: captureView)), hidden: \(node.isHiddenOrHasHiddenAncestor), visible rect: \(node.visibleRect)"
            }
            if let toolbar = window.toolbar {
                let visible = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
                for item in toolbar.items {
                    geometry.append("Toolbar item: \(item.itemIdentifier.rawValue), label: \(item.label), visible: \(visible.contains(item.itemIdentifier)), \(item.view.map(describe) ?? "system-managed view")")
                    if let group = item as? NSToolbarItemGroup {
                        geometry.append("Toolbar group members: \(group.subitems.map { $0.itemIdentifier.rawValue })")
                    }
                }
            }
            var searchField: NSSearchField?
            @MainActor func inspectControls(_ child: NSView) {
                if let segmented = child as? NSSegmentedControl {
                    let labels = (0..<segmented.segmentCount).map { segmented.label(forSegment: $0) ?? "" }
                    geometry.append("Segments: \(labels), intrinsic width: \(segmented.intrinsicContentSize.width), \(describe(segmented))")
                }
                if let field = child as? NSSearchField {
                    searchField = field
                    geometry.append("Search: \(field.placeholderString ?? ""), \(describe(field))")
                } else if let field = child as? NSTextField {
                    geometry.append("Text: \(field.stringValue), line break mode: \(field.lineBreakMode.rawValue), \(describe(field))")
                }
                if let button = child as? NSPopUpButton {
                    geometry.append("Menu: \(button.itemTitles), \(describe(button))")
                } else if let button = child as? NSButton {
                    geometry.append("Button: \(button.title), accessibility label: \(button.accessibilityLabel() ?? ""), tooltip: \(button.toolTip ?? ""), enabled: \(button.isEnabled), \(describe(button))")
                }
                for subview in child.subviews { inspectControls(subview) }
            }
            inspectControls(captureView)
            if let outline = findOutline(view), let header = outline.headerView { geometry.append("Table header frame: \(header.convert(header.bounds, to: captureView))") }
            var uploadChecksPassed = true
            if !fileBadges, !qbImport, !multiselect, let outline = findOutline(view),
               let column = outline.tableColumns.first(where: { $0.identifier.rawValue == "uploaded" }) {
                for (name, expected, partial) in [("Guide.pdf", Int64(120_000), true), ("Movie.mp4", Int64(720_000_000), false)] {
                    let node = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? TorrentTreeNode }.first { $0.name == name }
                    let cell = node.flatMap { outline.delegate?.outlineView?(outline, viewFor: column, item: $0) as? NSTableCellView }
                    let passed = cell?.textField?.stringValue == byteString(expected) + (partial ? "*" : "")
                        && (!partial || cell?.toolTip?.contains("since per-file tracking started") == true)
                    geometry.append("\(passed ? "PASS" : "FAIL"): Per-file uploaded total and history label for \(name)")
                    uploadChecksPassed = uploadChecksPassed && passed
                }
            }
            var searchChecksPassed = true
            if arguments.contains("--ui-search-check") {
                @MainActor func check(_ condition: Bool, _ message: String) {
                    geometry.append("\(condition ? "PASS" : "FAIL"): Search check: \(message)")
                    if !condition { searchChecksPassed = false }
                }
                if let field = searchField {
                    check(!field.isHiddenOrHasHiddenAncestor && !field.visibleRect.isEmpty, "Search field is visible in the toolbar")
                    field.stringValue = "Guide"
                    let sentGuide = field.sendAction(field.action, to: field.target)
                    check(sentGuide && search == "Guide", "Native search action updates the model")
                    searchFocusRequest += 1
                    try? await Task.sleep(for: .milliseconds(100))
                    check(field.currentEditor() != nil, "Search focus request activates the field editor")
                    field.stringValue = ""
                    let sentClear = field.sendAction(field.action, to: field.target)
                    check(sentClear && search.isEmpty, "Clearing the native search clears the model")
                    search = "Movie"
                    try? await Task.sleep(for: .milliseconds(100))
                    check(field.stringValue == "Movie", "Model changes update the native search field")
                    search = ""
                    try? await Task.sleep(for: .milliseconds(100))
                    check(field.stringValue.isEmpty, "Model reset clears the native search field")
                    window.makeFirstResponder(nil)
                } else {
                    check(false, "Search field was not found in the toolbar")
                }
            }
            var appearanceChecksPassed = true
            if arguments.contains("--ui-appearance-check") {
                let result = await checkDebugAppearance(directory: directory, restoreDark: dark)
                geometry.append(contentsOf: result.lines)
                appearanceChecksPassed = result.passed
            }
            try? geometry.joined(separator: "\n").write(to: directory.appendingPathComponent(basename + ".txt"), atomically: true, encoding: .utf8)
            let importSheetVisible = !qbImport || window.attachedSheet != nil
            if qbImport { print("\(importSheetVisible ? "PASS" : "FAIL"): qBittorrent import sheet is visible") }
            captured = searchChecksPassed && appearanceChecksPassed && importChecksPassed && importSheetVisible && multiselectResult.passed && uploadChecksPassed
            print("UI snapshot: \(output.path)")
        }
    }

    /// Exercises native selection notifications and refreshes without invoking engine or filesystem actions.
    private func checkDebugMultiselection(outline: NSOutlineView) async -> (passed: Bool, lines: [String]) {
        var passed = true
        var lines: [String] = []
        func check(_ condition: Bool, _ message: String) {
            let line = "\(condition ? "PASS" : "FAIL"): Multiselection check: \(message)"
            lines.append(line); print(line)
            if !condition { passed = false }
        }
        guard let coordinator = outline.delegate as? TorrentOutlineView.Coordinator else {
            check(false, "Outline coordinator is available")
            return (passed, lines)
        }
        func visibleNodes() -> [TorrentTreeNode] {
            (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? TorrentTreeNode }
        }
        func selectedNodeIDs() -> Set<String> { Set(selectedNodes.map(\.id)) }
        func nativeSelectionIDs() -> Set<String> {
            Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? TorrentTreeNode)?.id })
        }
        func select(_ ids: Set<String>) {
            let rows = IndexSet((0..<outline.numberOfRows).filter { row in
                (outline.item(atRow: row) as? TorrentTreeNode).map { ids.contains($0.id) } ?? false
            })
            outline.selectRowIndexes(rows, byExtendingSelection: false)
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(120)) }

        let originalTransfers = transfers
        let nodes = visibleNodes()
        guard let downloading = nodes.first(where: { node in
            if case .torrent(let id) = node.kind { return transfers.first(where: { $0.id == id })?.state == .downloading }
            return false
        }), let completed = nodes.first(where: { node in
            if case .torrent(let id) = node.kind { return transfers.first(where: { $0.id == id }).map { [.seeding, .completed].contains($0.state) } ?? false }
            return false
        }), let leaf = nodes.first(where: { node in
            if case .file = node.kind { return node.transferIDs == downloading.transferIDs }
            return false
        }), let parent = nodes.first(where: { node in
            node.kind == .folder && node.fileIndices == nil && node.transferIDs.isSuperset(of: downloading.transferIDs)
        }) else {
            check(false, "Fixture has downloading and completed torrents, a payload file, and a containing folder")
            return (passed, lines)
        }
        let pair: Set<String> = [downloading.id, completed.id]
        let pairTransferIDs = downloading.transferIDs.union(completed.transferIDs)
        check(outline.allowsMultipleSelection, "Native outline enables multiple selection")
        select([downloading.id])
        let completedRow = outline.row(forItem: completed)
        outline.selectRowIndexes(IndexSet(integer: completedRow), byExtendingSelection: true)
        check(selectedNodeIDs() == pair && nativeSelectionIDs() == pair, "Extending native selection updates both selected rows in the model")
        check(selectedIDs == pairTransferIDs && selectedTransfer == nil, "Two torrents provide batch action IDs and no ambiguous inspector transfer")
        check(Set(selectedURLs) == Set([downloading.url, completed.url].compactMap { $0 }), "Reveal targets include both selected URLs")
        check(coordinator.prepareContextSelection(row: completedRow) && selectedNodeIDs() == pair, "Context menu on a selected row preserves the whole selection")
        check(coordinator.prepareContextSelection(row: outline.row(forItem: leaf)) && selectedNodeIDs() == [leaf.id], "Context menu on an unselected row switches to that row")
        check(selectedIDs.isEmpty && selectedTransfer?.id == downloading.transferIDs.first, "Payload file selection inspects its torrent without targeting torrent batch actions")
        select([downloading.id, leaf.id])
        check(selectedIDs == downloading.transferIDs && selectedTransfer?.id == downloading.transferIDs.first, "Torrent and its payload deduplicate to one inspector transfer")
        select([parent.id, downloading.id, leaf.id])
        check(selectedIDs == parent.transferIDs, "Overlapping folder, torrent, and payload selections deduplicate action IDs")

        outline.window?.makeFirstResponder(outline)
        let selectAllSent = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        check(selectAllSent && outline.selectedRowIndexes.count == outline.numberOfRows && selectedNodes.count == outline.numberOfRows, "Native Select All selects every visible row and updates the model")
        check(selectedIDs == Set(transfers.filter { $0.state != .resolving }.map(\.id)), "Select All deduplicates ancestor and descendant torrent targets")

        select(pair)
        let oldGeneration = tree.generation
        if let index = transfers.firstIndex(where: { downloading.transferIDs.contains($0.id) }) { transfers[index].downloadRate += 1 }
        coordinator.refresh(model: self)
        await settle()
        check(tree.generation == oldGeneration && selectedNodeIDs() == pair && nativeSelectionIDs() == pair, "Progress refresh preserves multiple selected rows without rebuilding the tree")
        // Fixture mode intentionally avoids writing expansion preferences; retain its expanded branches in memory.
        coordinator.expanded = Set(visibleNodes().filter { outline.isItemExpanded($0) }.map(\.id))
        transfers.append(TransferSnapshot(id: "ui-multiselect-added", name: "New fixture.iso", destination: URL(fileURLWithPath: "/Volumes/Storage/torrents/other"), state: .paused))
        coordinator.refresh(model: self)
        await settle()
        check(tree.generation > oldGeneration && selectedNodeIDs() == pair && nativeSelectionIDs() == pair, "Structural rebuild restores every selected row by stable ID")
        check(selectedNodes.allSatisfy { selected in visibleNodes().contains { $0 === selected } }, "Rebuilt selection references the current tree nodes")
        filter = .completed
        coordinator.refresh(model: self)
        await settle()
        check(selectedNodeIDs() == [completed.id] && nativeSelectionIDs() == [completed.id] && selectedIDs == completed.transferIDs, "Filtering removes hidden selections from batch targets")
        filter = .all
        coordinator.refresh(model: self)
        await settle()
        check(selectedNodeIDs() == [completed.id], "Clearing a filter does not restore hidden batch targets")

        do {
            let legacy = try JSONDecoder().decode(UIState.self, from: Data(#"{"version":1,"notificationsEnabled":false,"filter":"All Transfers","inspectorVisible":false,"expandedNodeIDs":[],"hasSavedExpansion":false,"selectedNodeID":"torrent:legacy","columnOrder":[],"columnWidths":{}}"#.utf8))
            check(Set(legacy.effectiveSelectedNodeIDs) == ["torrent:legacy"], "Legacy single-row preferences restore as a selection")
            var state = legacy
            state.selectedNodeIDs = pair.sorted()
            let decoded = try JSONDecoder().decode(UIState.self, from: JSONEncoder().encode(state))
            check(Set(decoded.effectiveSelectedNodeIDs) == pair, "Multiple selected row IDs survive preferences serialization")
            state.selectedNodeIDs = []
            check(state.effectiveSelectedNodeIDs.isEmpty, "An explicit empty selection overrides the legacy selected row")

            let originalState = uiState
            defer { uiState = originalState }
            var restoredState = decoded
            restoredState.expandedNodeIDs = coordinator.expanded.sorted()
            restoredState.hasSavedExpansion = true
            uiState = restoredState
            let restoredOutline = NSOutlineView()
            restoredOutline.allowsMultipleSelection = true
            let restoredCoordinator = TorrentOutlineView.Coordinator(model: self)
            restoredCoordinator.outline = restoredOutline
            restoredOutline.dataSource = restoredCoordinator
            restoredOutline.delegate = restoredCoordinator
            restoredCoordinator.refresh(model: self)
            await settle()
            let restoredIDs = Set(restoredOutline.selectedRowIndexes.compactMap { (restoredOutline.item(atRow: $0) as? TorrentTreeNode)?.id })
            check(restoredIDs == pair && selectedNodeIDs() == pair, "Fresh outline restores serialized multiple selection through its normal loading path")
            uiState.selectedNodeIDs = nil
            uiState.selectedNodeID = completed.id
            restoredCoordinator.loadedState = false
            restoredCoordinator.refresh(model: self)
            await settle()
            let legacyIDs = Set(restoredOutline.selectedRowIndexes.compactMap { (restoredOutline.item(atRow: $0) as? TorrentTreeNode)?.id })
            check(legacyIDs == [completed.id] && selectedNodeIDs() == [completed.id], "Outline restores the legacy single selection through the same loading path")
        } catch {
            check(false, "Selection preferences decode and encode: \(error.localizedDescription)")
        }

        transfers = originalTransfers
        coordinator.refresh(model: self)
        await settle()
        outline.expandItem(nil, expandChildren: true)
        select(pair)
        outline.window?.makeFirstResponder(outline)
        return (passed, lines)
    }

    private func installDebugQBittorrentImport() -> Bool {
        let source = URL(fileURLWithPath: "/Users/fixture/Library/Application Support/qBittorrent/BT_backup", isDirectory: true)
        let destination = URL(fileURLWithPath: "/Volumes/Storage/torrents", isDirectory: true)
        let existingID = String(repeating: "b", count: 40)
        let draft = QBittorrentImportDraft(existingIDs: [existingID])
        draft.sourceURL = source
        draft.candidates = [
            QBittorrentImportCandidate(
                id: String(repeating: "a", count: 40), name: "Open Movie Collection",
                torrentURL: source.appendingPathComponent("a.torrent"), resumeURL: source.appendingPathComponent("a.fastresume"),
                destination: destination, selectedFiles: [0, 1, 2], downloadedBytes: 4_200_000_000,
                uploadedBytes: 1_600_000_000, totalBytes: 8_400_000_000, fileCount: 3
            ),
            QBittorrentImportCandidate(
                id: existingID, name: "Linux.iso",
                torrentURL: source.appendingPathComponent("b.torrent"), resumeURL: source.appendingPathComponent("b.fastresume"),
                destination: destination, selectedFiles: [0], downloadedBytes: 4_000_000_000,
                totalBytes: 4_000_000_000, fileCount: 1
            ),
            QBittorrentImportCandidate(
                id: String(repeating: "c", count: 40), name: "Renamed video collection",
                torrentURL: source.appendingPathComponent("c.torrent"), resumeURL: source.appendingPathComponent("c.fastresume"),
                destination: destination, totalBytes: 12_000_000_000, fileCount: 10,
                issue: "Renamed or remapped files are not supported. Restore their original names in qBittorrent first."
            )
        ]
        qbittorrentImport = draft
        var passed = true
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL"): qBittorrent import check: \(message)")
            if !condition { passed = false }
        }
        draft.selectVisible()
        check(draft.selection == [String(repeating: "a", count: 40)], "Select Shown excludes existing and unsupported torrents")
        draft.selection = []
        draft.search = "Linux"
        draft.selectVisible()
        check(draft.visibleCandidates.count == 1 && draft.selection.isEmpty, "Searching narrows rows and keeps duplicates unselected")
        draft.search = "Open Movie"
        draft.selectVisible()
        check(draft.selection == [String(repeating: "a", count: 40)], "Filtered selection includes the eligible torrent")
        draft.search = ""
        check(draft.verifyExistingData, "Existing-data verification is enabled by default")
        draft.verifyExistingData = false
        check(draft.status(draft.candidates[0]) == "Ready to import", "Unchecked verification uses saved-progress import status")
        draft.verifyExistingData = true
        check(draft.status(draft.candidates[0]) == "Ready to verify", "Re-enabling verification restores the checking status")
        if ProcessInfo.processInfo.arguments.contains("--ui-qb-skip-verification") { draft.verifyExistingData = false }
        check(!canSwitchProfile && !canImportFromQBittorrent, "Open import sheet prevents profile changes and overlapping imports")
        return passed
    }

    private func checkDebugAppearance(directory: URL, restoreDark: Bool) async -> (passed: Bool, lines: [String]) {
        var passed = true
        var lines: [String] = []
        func check(_ condition: Bool, _ message: String) {
            let line = "\(condition ? "PASS" : "FAIL"): Appearance check: \(message)"
            lines.append(line)
            print(line)
            if !condition { passed = false }
        }
        let previouslyLoaded = didLoadUIState
        didLoadUIState = false
        defer {
            appearance = restoreDark ? .dark : .light
            didLoadUIState = previouslyLoaded
        }
        do {
            let legacyJSON = Data(#"{"version":1,"notificationsEnabled":true,"filter":"paused","inspectorVisible":true,"expandedNodeIDs":["torrent:legacy"],"hasSavedExpansion":true,"selectedNodeID":"torrent:legacy","columnOrder":["name","size"],"columnWidths":{"name":417}}"#.utf8)
            let legacy = try JSONDecoder().decode(UIState.self, from: legacyJSON)
            var expected = UIState()
            expected.notificationsEnabled = true
            expected.filter = "paused"
            expected.inspectorVisible = true
            expected.expandedNodeIDs = ["torrent:legacy"]
            expected.hasSavedExpansion = true
            expected.selectedNodeID = "torrent:legacy"
            expected.columnOrder = ["name", "size"]
            expected.columnWidths = ["name": 417]
            check(legacy == expected && legacy.appearance == nil, "Legacy state preserves all fields without a theme")
            for theme in AppAppearance.allCases {
                var state = legacy
                state.appearance = theme
                let decoded = try JSONDecoder().decode(UIState.self, from: JSONEncoder().encode(state))
                check(decoded == state, "\(theme.title) theme round-trips with existing interface preferences")
            }
            appearance = .system
            check(NSApp.appearance == nil, "System theme follows macOS")

            let hostingView = NSHostingView(rootView: SettingsView(model: self))
            let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settingsWindow.title = "Settings — Appearance Fixture"
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.contentView = hostingView
            settingsWindow.center()
            settingsWindow.makeKeyAndOrderFront(nil)
            defer { settingsWindow.close() }
            for theme in [AppAppearance.light, .dark] {
                appearance = theme
                let expectedName: NSAppearance.Name = theme == .dark ? .darkAqua : .aqua
                check(NSApp.appearance?.name == expectedName, "\(theme.title) selection updates application appearance")
                try await Task.sleep(for: .milliseconds(500))
                check(hostingView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expectedName, "Settings inherits \(theme.title.lowercased()) appearance")
                let captureView = hostingView.superview ?? hostingView
                captureView.layoutSubtreeIfNeeded()
                captureView.displayIfNeeded()
                if let bitmap = captureView.bitmapImageRepForCachingDisplay(in: captureView.bounds) {
                    captureView.cacheDisplay(in: captureView.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        let output = directory.appendingPathComponent("ui-settings-\(theme.rawValue).png")
                        try png.write(to: output, options: .atomic)
                        check(true, "Settings screenshot written: \(output.path)")
                    } else { check(false, "Could not encode \(theme.title.lowercased()) settings screenshot") }
                } else { check(false, "Could not capture \(theme.title.lowercased()) settings screenshot") }
            }
        } catch { check(false, "\(error)") }
        return (passed, lines)
    }
}

@MainActor extension AppModel {
    /// Runs the actual app model against temporary databases, never the user's library.
    func runProfileSmoke() async {
        let reportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Torrenza-Profile-Smoke", isDirectory: true)
        var lines: [String] = []
        struct SmokeFailure: Error { let message: String }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw SmokeFailure(message: message) }
            lines.append("PASS: " + message)
        }
        do {
            try require(isProfileReady && activeProfile?.id == "default", "Existing root opens as Default")
            let original = activeProfile!
            let originalSession = statistics!.current.id
            let originalTorrentDirectory = original.directory.appendingPathComponent("Torrent Files", isDirectory: true)
            let originalDestinationDirectory = original.directory.appendingPathComponent("Downloads", isDirectory: true)
            settings.maxDownloads = 3; saveSettings()
            uiState.filter = TreeFilter.completed.rawValue
            uiState.columnWidths["name"] = 417
            uiState.lastTorrentDirectory = originalTorrentDirectory
            uiState.lastDestinationDirectory = originalDestinationDirectory
            guard var legacyState = try JSONSerialization.jsonObject(with: JSONEncoder().encode(uiState)) as? [String: Any] else {
                throw SmokeFailure(message: "Could not prepare legacy interface preferences")
            }
            legacyState.removeValue(forKey: "lastTorrentDirectory")
            legacyState.removeValue(forKey: "lastDestinationDirectory")
            let decodedLegacy = try JSONDecoder().decode(UIState.self, from: JSONSerialization.data(withJSONObject: legacyState))
            try require(decodedLegacy.lastTorrentDirectory == nil && decodedLegacy.lastDestinationDirectory == nil && decodedLegacy.filter == uiState.filter && decodedLegacy.columnWidths == uiState.columnWidths, "Legacy interface preferences load without saved dialog directories")
            await waitForProfileWork()
            beginCreateProfile(); profileName = "Work"; submitProfile()
            await waitForProfileWork()
            try require(error == nil && activeProfile?.name == "Work", "Creating a profile activates it")
            let work = activeProfile!
            try require(work.databaseURL != original.databaseURL && transfers.isEmpty, "New profile uses an independent empty database")
            try require(settings.maxDownloads == 2 && filter == .all && uiState.columnWidths.isEmpty, "Settings and interface preferences do not leak")
            try require(uiState.lastTorrentDirectory == nil && uiState.lastDestinationDirectory == nil, "New profile starts without another profile's dialog directories")
            try require(statistics?.current.id != originalSession && statistics?.lifetimeDownloadedBytes == 0, "Statistics start independently")
            let workTorrentDirectory = work.directory.appendingPathComponent("Torrent Files", isDirectory: true)
            let workDestinationDirectory = work.directory.appendingPathComponent("Downloads", isDirectory: true)
            settings.maxDownloads = 1; saveSettings(); filter = .paused
            uiState.lastTorrentDirectory = workTorrentDirectory
            uiState.lastDestinationDirectory = workDestinationDirectory
            await waitForProfileWork()
            switchProfile(original); await waitForProfileWork()
            try require(settings.maxDownloads == 3 && filter == .completed && uiState.columnWidths["name"] == 417, "Switching back restores settings and interface preferences")
            try require(uiState.lastTorrentDirectory == originalTorrentDirectory && uiState.lastDestinationDirectory == originalDestinationDirectory, "Switching back restores both original profile dialog directories")
            try require(statistics?.current.id != originalSession, "Returning to a profile begins a new session")
            let history = try await engine.sessionHistory()
            try require(history.contains { $0.id == originalSession && $0.endedAt != nil && !$0.interrupted }, "Switching closes the previous session cleanly")
            beginCreateProfile(); profileName = "work"; submitProfile(); await waitForProfileWork()
            try require(profileEditorError != nil && activeProfile?.id == original.id, "Duplicate names leave the active profile unchanged")
            profileEditor = nil; profileEditorError = nil
            switchProfile(work); await waitForProfileWork()
            try require(settings.maxDownloads == 1 && filter == .paused, "Second profile retains its own values")
            try require(uiState.lastTorrentDirectory == workTorrentDirectory && uiState.lastDestinationDirectory == workDestinationDirectory, "Second profile retains its own distinct dialog directories")
            beginRenameProfile(); profileName = "Research"; submitProfile(); await waitForProfileWork()
            try require(activeProfile?.id == work.id && activeProfile?.name == "Research", "Rename preserves database identity")
            let store = SQLiteStore(url: original.databaseURL)
            let oldState = try await store.read(namespace: "ui", key: "state")
            try await store.write([SQLiteEntry(namespace: "ui", key: "state", value: Data("invalid-json".utf8))])
            try await store.close()
            let currentEngine = engine
            switchProfile(original); await waitForProfileWork()
            try require(error != nil && activeProfile?.id == work.id && engine === currentEngine && isProfileReady, "Invalid target UI state preserves the running profile")
            error = nil
            let repair = SQLiteStore(url: original.databaseURL)
            try await repair.write([SQLiteEntry(namespace: "ui", key: "state", value: oldState)])
            try await repair.close()
            // Allow SwiftUI to lay out the completed transition before measuring native controls.
            try await Task.sleep(for: .milliseconds(300))
            if let window = NSApp.windows.first(where: { $0.title.contains("Torrenza") }), let view = window.contentView {
                window.setContentSize(NSSize(width: 1000, height: 700))
                try await Task.sleep(for: .milliseconds(300))
                let container = view.superview ?? view
                container.layoutSubtreeIfNeeded()
                func inspect(_ node: NSView) throws {
                    if let control = node as? NSSegmentedControl, control.segmentCount == 5 {
                        try require(control.isEnabled && control.intrinsicContentSize.width <= control.frame.width + 1, "Five filter buttons remain enabled and fit at minimum window width")
                        lines.append("Filter frame: \(control.convert(control.bounds, to: container))")
                    }
                    for child in node.subviews { try inspect(child) }
                }
                try inspect(container)
                if let bitmap = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
                    container.cacheDisplay(in: container.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: reportDirectory.appendingPathComponent("profiles.png"))
                    }
                }
            }
            await shutdown()
            let reopened = AppModel(root: original.directory, defaults: profileDefaults)
            reopened.launch(); await reopened.waitForProfileWork()
            try require(reopened.activeProfile?.id == work.id && reopened.activeProfile?.name == "Research", "Relaunch restores the last selected profile and name")
            try require(reopened.settings.maxDownloads == 1 && reopened.filter == .paused, "Relaunch restores profile settings")
            try require(reopened.uiState.lastTorrentDirectory == workTorrentDirectory && reopened.uiState.lastDestinationDirectory == workDestinationDirectory, "Relaunch restores both saved dialog directories")
            await reopened.shutdown()
            let closedDatabase = try Data(contentsOf: work.databaseURL)
            await shutdown()
            try require(try Data(contentsOf: work.databaseURL) == closedDatabase, "Repeated shutdown does not rewrite a closed profile")
            lines.append("PROFILE SMOKE PASSED")
        } catch { lines.append("PROFILE SMOKE FAILED: \(error)") }
        try? FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: reportDirectory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
        // Do not enter AppKit's synchronous termination loop from a MainActor task.
        // The isolated harness exits only after explicit persistence shutdown.
        await shutdown()
        exit(lines.last == "PROFILE SMOKE PASSED" ? 0 : 1)
    }
}
#endif
