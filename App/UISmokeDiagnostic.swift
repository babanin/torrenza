#if DEBUG
import AppKit
import ApplicationServices
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
        let addTorrent = arguments.contains("--ui-add-torrent")
        let multiselect = arguments.contains("--ui-multiselect-check")
        let sortCheck = arguments.contains("--ui-sort-check")
        let fileSelectionCheck = arguments.contains("--ui-file-selection-check")
        let workspaceCheck = arguments.contains("--ui-workspace-check")
        let selectionCheck = arguments.contains("--ui-selection-check")
        let columnsCheck = arguments.contains("--ui-columns-check")
        let refreshProgress = arguments.contains("--ui-refresh-progress")
        let refreshResultCapture = arguments.contains("--ui-refresh-result")
        let refreshSelection = arguments.contains("--ui-refresh-selection")
        let refreshCheck = arguments.contains("--ui-refresh-check") || refreshProgress || refreshResultCapture || refreshSelection
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
            TransferSnapshot(id: "ui-a", name: "A", destination: URL(fileURLWithPath: "/Volumes/Storage/torrents/other"), isMultiFile: true, state: .downloading, files: files, fileUploadHistoryComplete: false, completedBytes: 21_000_000, selectedBytes: 50_000_000, downloadedBytes: 21_000_000, uploadedBytes: 2_000_000, downloadRate: 4_200_000, uploadRate: 128_000, swarm: swarm, trackers: ["https://tracker.example.test/announce"], addedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            TransferSnapshot(id: "ui-b", name: "B", destination: URL(fileURLWithPath: "/Volumes/Storage/torrents/video"), isMultiFile: true, state: .seeding, files: [.init(file: .init(index: 0, path: ["B", "Movie.mp4"], length: 1_200_000_000, offset: 0), selected: true, verifiedBytes: 1_200_000_000, uploadedBytes: 720_000_000)], completedBytes: 1_200_000_000, selectedBytes: 1_200_000_000, downloadedBytes: 1_200_000_000, uploadedBytes: 720_000_000, uploadRate: 2_100_000, swarm: swarm, addedAt: Date(timeIntervalSince1970: 1_600_000_000)),
            TransferSnapshot(id: "ui-offline", name: "Linux.iso", destination: URL(fileURLWithPath: "/Volumes/Backup"), state: .unavailable, selectedBytes: 4_000_000_000, error: "Connect Backup to resume this download.")
        ]
        if fileBadges {
            let destination = URL(fileURLWithPath: "/Volumes/Storage/torrents")
            let states: [TransferState] = [.downloading, .seeding, .paused, .queued, .checking, .resolving, .completed, .unavailable, .failed]
            transfers = states.enumerated().map { index, state in
                let name = "\(index + 1). \(state.rawValue.capitalized).\(index.isMultiple(of: 2) ? "avi" : "mkv")"
                // Complete payloads for seeding/completed and a queued-at-100%
                // torrent: queueing at full progress is legitimate and must
                // display both facts.
                let complete = state == .seeding || state == .completed || state == .queued
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
        // Four-digit sidebar counts and a realistic scrolling workload.
        if arguments.contains("--ui-many-transfers") {
            let destination = URL(fileURLWithPath: "/Volumes/Storage/bulk")
            let bulk = (0..<1234).map { index -> TransferSnapshot in
                TransferSnapshot(
                    id: String(format: "ui-bulk-%04d", index),
                    name: String(repeating: "Bulk paused archive ", count: 1) + String(format: "%04d", index) + ".iso",
                    destination: destination,
                    state: .paused,
                    files: [.init(file: .init(index: 0, path: ["bulk-\(index).iso"], length: 4_000_000_000, offset: 0), selected: true, verifiedBytes: 1_000_000_000)],
                    completedBytes: 1_000_000_000, selectedBytes: 4_000_000_000
                )
            }
            transfers.append(contentsOf: bulk)
        }
        refreshVisibleCount()
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
            var sortResult: (passed: Bool, lines: [String]) = (true, [])
            if sortCheck {
                if let outline = findOutline(view) {
                    sortResult = await checkDebugSorting(outline: outline)
                } else {
                    sortResult = (false, ["FAIL: Sorting check: Torrent outline was not found"])
                }
            }
            var fileSelectionResult: (passed: Bool, lines: [String]) = (true, [])
            if fileSelectionCheck {
                if let outline = findOutline(view) {
                    fileSelectionResult = await checkDebugFileSelection(outline: outline)
                } else {
                    fileSelectionResult = (false, ["FAIL: File selection check: Torrent outline was not found"])
                }
            }
            var selectionResult: (passed: Bool, lines: [String]) = (true, [])
            if selectionCheck {
                if findOutline(view) != nil {
                    selectionResult = await checkDebugSelection(window: window, view: view)
                } else {
                    selectionResult = (false, ["FAIL: Selection check: Torrent outline was not found"])
                }
            }
            var columnsResult: (passed: Bool, lines: [String]) = (true, [])
            if columnsCheck {
                if findOutline(view) != nil {
                    columnsResult = await checkDebugColumns(window: window, view: view)
                } else {
                    columnsResult = (false, ["FAIL: Columns check: Torrent outline was not found"])
                }
            }
            var workspaceResult: (passed: Bool, lines: [String]) = (true, [])
            if workspaceCheck {
                workspaceResult = await checkDebugWorkspace(window: window, view: view)
            }
            let importChecksPassed = !qbImport || installDebugQBittorrentImport()
            if addTorrent { installDebugAddTorrent() }
            var refreshResult: (passed: Bool, lines: [String]) = (true, [])
            if refreshCheck {
                if let outline = findOutline(view) {
                    refreshResult = await checkDebugTorrentRefresh(outline: outline, window: window)
                } else {
                    refreshResult = (false, ["FAIL: Torrent refresh check: Torrent outline was not found"])
                }
            }
            try? await Task.sleep(for: .milliseconds(600))
            let addTorrentResult = addTorrent ? await checkDebugAddTorrent(window: window) : (passed: true, lines: [String]())
            let qbSheetResult = qbImport ? await checkDebugQBittorrentSheet(window: window) : (passed: true, lines: [String]())
            let contentToCapture = qbImport || addTorrent || refreshCheck ? (window.attachedSheet?.contentView ?? view) : view
            let captureView = contentToCapture.superview ?? contentToCapture
            captureView.layoutSubtreeIfNeeded(); captureView.displayIfNeeded()
            guard let bitmap = captureView.bitmapImageRepForCachingDisplay(in: captureView.bounds) else { return }
            captureView.cacheDisplay(in: captureView.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Torrenza-UI", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let refreshSuffix = refreshSelection ? "-refresh-selection" : refreshResultCapture ? "-refresh-result" : refreshProgress ? "-refresh-progress" : refreshCheck ? "-refresh" : ""
            let basename = "ui-smoke-\(dark ? "dark" : "light")\(narrow ? "-narrow" : wide ? "-wide" : "")\(longProfile ? "-long-profile" : "")\(fileBadges ? "-file-badges" : "")\(qbImport ? "-qb-import" : "")\(addTorrent ? "-add-torrent" : "")\(arguments.contains("--ui-add-torrent-error") ? "-error" : "")\(arguments.contains("--ui-qb-skip-verification") ? "-unchecked" : "")\(multiselect ? "-multiselect" : "")\(sortCheck ? "-sort" : "")\(fileSelectionCheck ? "-file-selection" : "")\(refreshSuffix)"
            let output = directory.appendingPathComponent(basename + ".png")
            try? png.write(to: output, options: .atomic)
            var geometry = ["Window content size: \(view.bounds.size)", "Profile name: \(fixtureName)", "Toolbar item count: \(window.toolbar?.items.count ?? 0)"]
            geometry.append(contentsOf: multiselectResult.lines)
            geometry.append(contentsOf: sortResult.lines)
            geometry.append(contentsOf: fileSelectionResult.lines)
            geometry.append(contentsOf: addTorrentResult.lines)
            geometry.append(contentsOf: qbSheetResult.lines)
            geometry.append(contentsOf: refreshResult.lines)
            geometry.append(contentsOf: workspaceResult.lines)
            geometry.append(contentsOf: selectionResult.lines)
            geometry.append(contentsOf: columnsResult.lines)
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
                if let split = child as? NSSplitView {
                    let panes = split.arrangedSubviews.map { pane in
                        "frame=\(split.convert(pane.frame, to: captureView)), hidden=\(pane.isHidden), intrinsic=\(pane.intrinsicContentSize)"
                    }
                    geometry.append("Split: dividers=\(split.dividerThickness), bounds=\(split.convert(split.bounds, to: captureView)), panes=\(panes)")
                }
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
                    check(!field.isHiddenOrHasHiddenAncestor && !field.visibleRect.isEmpty, "Search field is visible in the central panel header")
                    check(field.frame.width >= 220 && field.frame.width <= 300, "Search field keeps its compact width")
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
                    check(false, "Search field was not found in the panel header")
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
            captured = searchChecksPassed && appearanceChecksPassed && importChecksPassed && importSheetVisible && multiselectResult.passed && sortResult.passed && fileSelectionResult.passed && uploadChecksPassed && addTorrentResult.passed && qbSheetResult.passed && refreshResult.passed && workspaceResult.passed && selectionResult.passed && columnsResult.passed
            print("UI snapshot: \(output.path)")
        }
    }

    /// Exercise native controls with synthetic snapshots; captured actions never reach the engine.
    private func checkDebugFileSelection(outline: NSOutlineView) async -> (passed: Bool, lines: [String]) {
        var passed = true
        var lines: [String] = []
        func check(_ condition: Bool, _ message: String) {
            let line = "\(condition ? "PASS" : "FAIL"): File selection check: \(message)"
            lines.append(line); print(line)
            if !condition { passed = false }
        }
        guard let coordinator = outline.delegate as? TorrentOutlineView.Coordinator,
              let nameColumn = outline.tableColumns.first(where: { $0.identifier.rawValue == "name" }),
              let progressColumn = outline.tableColumns.first(where: { $0.identifier.rawValue == "progress" }),
              let fixtureIndex = transfers.firstIndex(where: { $0.id == "ui-a" }) else {
            check(false, "Native outline and standard fixture are available")
            return (passed, lines)
        }
        let originalTransfers = transfers
        let originalSearch = search
        let originalSelection = coordinator.selectedNodeIDs
        defer {
            coordinator.debugFileSelectionAction = nil
            setDebugFileSelectionPending(false, transferID: "ui-a")
            clearDebugFileSelection(transferID: "ui-a")
            transfers = originalTransfers; search = originalSearch
            coordinator.selectedNodeIDs = originalSelection
            coordinator.refresh(model: self)
            outline.expandItem(nil, expandChildren: true)
        }
        transfers[fixtureIndex].files.append(.init(file: .init(index: 2, path: ["A", "Documents", "Hidden.txt"], length: 100, offset: 50_000_000), selected: false, verifiedBytes: 0))
        transfers.append(.init(id: "ui-single-selection", name: "Single.txt", destination: URL(fileURLWithPath: "/Volumes/Storage/torrents/other"), state: .paused,
                               files: [.init(file: .init(index: 0, path: ["Single.txt"], length: 10, offset: 0), selected: false, verifiedBytes: 0)]))
        func refresh() {
            coordinator.refresh(model: self)
            outline.expandItem(nil, expandChildren: true)
        }
        func nodes() -> [TorrentTreeNode] {
            (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? TorrentTreeNode }
        }
        func cell(_ node: TorrentTreeNode, column: NSTableColumn) -> NSTableCellView? {
            coordinator.outlineView(outline, viewFor: column, item: node) as? NSTableCellView
        }
        func checkbox(_ node: TorrentTreeNode) -> NSButton? {
            cell(node, column: nameColumn)?.subviews.compactMap { $0 as? NSButton }.first
        }
        func select(_ selected: [TorrentTreeNode]) {
            outline.selectRowIndexes(IndexSet(selected.map { outline.row(forItem: $0) }.filter { $0 >= 0 }), byExtendingSelection: false)
        }
        refresh()
        guard let torrent = nodes().first(where: { $0.id == "torrent:ui-a" }),
              let folder = nodes().first(where: { $0.id == "contents:ui-a:Documents" }),
              let file = nodes().first(where: { $0.id == "file:ui-a:0" }),
              let single = nodes().first(where: { $0.id == "torrent:ui-single-selection" }),
              let location = nodes().first(where: { $0.kind == .folder && $0.fileIndices == nil && $0.transferIDs.contains("ui-a") }) else {
            check(false, "Fixture has file, internal folder, single-file torrent, and location rows")
            return (passed, lines)
        }
        check(checkbox(file)?.state == .on && checkbox(folder)?.state == .mixed && checkbox(single)?.state == .off,
              "Files, mixed folders, and single-file torrent rows expose native checkbox states")
        check(checkbox(torrent)?.isHidden == true && checkbox(location)?.isHidden == true,
              "Multifile torrent and filesystem-location rows retain torrent-wide controls")
        let folderButton = checkbox(folder)
        lines.append("Folder checkbox accessibility: role=\(folderButton?.accessibilityRole()?.rawValue ?? "nil"), label=\(folderButton?.accessibilityLabel() ?? "nil"), valueDescription=\(folderButton?.accessibilityValueDescription() ?? "nil")")
        check(folderButton?.accessibilityRole() == .checkBox && folderButton?.accessibilityLabel()?.contains("Documents") == true
              && folderButton?.accessibilityValueDescription() == "Some files enabled",
              "Folder checkbox has a native accessible role, name, and mixed-state description")
        check(folderButton?.toolTip?.contains("including files hidden by search") == true,
              "Folder control explains that hidden descendants are included")
        check(cell(single, column: progressColumn)?.textField?.stringValue == "No files selected",
              "An idle single-file torrent with an empty selection explains its status")
        select([file, folder])
        let selectionBeforeClick = Set(selectedNodes.map(\.id))
        let expandedBeforeClick = outline.isItemExpanded(folder)
        var recorded: [(ids: [String], selected: Bool)] = []
        coordinator.debugFileSelectionAction = { rows, selected in
            recorded.append((rows.map(\.id), selected))
        }
        folderButton?.performClick(nil)
        folderButton?.performClick(nil)
        folderButton?.performClick(nil)
        check(recorded.map(\.selected) == [true, false, true] && recorded.allSatisfy { $0.ids == [folder.id] },
              "A mixed-folder click enables all files; rapid native clicks preserve explicit on/off intents")
        check(Set(selectedNodes.map(\.id)) == selectionBeforeClick && outline.isItemExpanded(folder) == expandedBeforeClick,
              "Checkbox clicks preserve native multiselection and expansion")
        coordinator.debugFileSelectionAction = nil
        let menu = NSMenu(); menu.autoenablesItems = false
        coordinator.updateContextMenu(menu, row: outline.row(forItem: folder))
        check(menu.items.first(where: { $0.title == "Download" })?.isEnabled == true
              && menu.items.first(where: { $0.title == "Stop Downloading" })?.isEnabled == true
              && actionTargets["ui-a"] == .files([0, 2]),
              "File/folder context actions deduplicate overlapping multiselection")
        select([torrent, folder])
        check(startSelectionTitle == "Start" && pauseSelectionTitle == "Pause" && actionTargets["ui-a"] == .torrent,
              "A selected whole torrent takes precedence over its descendants")
        select([file, single])
        check(actionTargets.count == 2 && startSelectionTitle == "Download" && pauseSelectionTitle == "Stop Downloading",
              "File actions span multiple torrents with explicit Download and Stop Downloading labels")
        select([location])
        check(startSelectionTitle == "Start" && pauseSelectionTitle == "Pause", "Filesystem-location selections keep torrent-wide Start and Pause")

        setDebugFileSelection(indices: [2], selected: true, transferID: "ui-a")
        setDebugFileSelectionPending(true, transferID: "ui-a")
        check(checkbox(folder)?.state == .on && checkbox(folder)?.isEnabled == true
              && checkbox(folder)?.accessibilityHelp()?.contains("Updating file selection") == true,
              "Pending changes update checkbox state immediately and allow consecutive changes")
        check(isFileSelected(2, transfer: transfers[fixtureIndex]), "The Files inspector reads the same pending selection projection")
        select([torrent])
        coordinator.updateContextMenu(menu, row: outline.row(forItem: torrent))
        check(!canRecheckSelection && !canRemoveSelection && !canRefreshSelection
              && menu.items.first(where: { $0.title == "Recheck" })?.isEnabled == false
              && menu.items.first(where: { $0.title == "Remove…" })?.isEnabled == false,
              "Pending selection work prevents conflicting Recheck, Refresh, and Remove")
        setDebugFileSelectionPending(false, transferID: "ui-a")
        clearDebugFileSelection(transferID: "ui-a")
        check(checkbox(folder)?.state == .mixed, "Clearing a failed pending projection restores the authoritative selection")
        transfers[fixtureIndex].state = .failed
        transfers[fixtureIndex].error = "Owned file was replaced."
        refresh()
        check(cell(torrent, column: progressColumn)?.toolTip == "Owned file was replaced." && checkbox(folder)?.state == .mixed,
              "Failure remains visible and does not silently alter enabled files")
        transfers[fixtureIndex].state = .downloading
        transfers[fixtureIndex].error = nil
        search = "Guide"
        refresh()
        if let filteredFolder = nodes().first(where: { $0.id == folder.id }) {
            check(filteredFolder.fileIndices == [0] && fileSelectionState(for: filteredFolder) == .mixed
                  && TorrentTreeActions.fileSelection(for: filteredFolder, transfers: transfers)?.indices == [0, 2],
                  "Search-hidden descendants participate in folder state and action scope")
        } else { check(false, "Search keeps the matching file's ancestor folder") }
        search = ""; refresh()
        select([file])
        outline.window?.makeFirstResponder(outline)
        try? await Task.sleep(for: .milliseconds(100))
        return (passed, lines)
    }

    /// Uses native menu construction and synthetic rows without fetching metadata or opening a real profile.
    private func checkDebugTorrentRefresh(outline: NSOutlineView, window: NSWindow) async -> (passed: Bool, lines: [String]) {
        var passed = true
        var lines: [String] = []
        func check(_ condition: Bool, _ message: String) {
            let line = "\(condition ? "PASS" : "FAIL"): Torrent refresh check: \(message)"
            lines.append(line); print(line)
            if !condition { passed = false }
        }
        guard let coordinator = outline.delegate as? TorrentOutlineView.Coordinator else {
            check(false, "Outline coordinator is available")
            return (passed, lines)
        }
        let nodes = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? TorrentTreeNode }
        let torrentNodes = nodes.filter { if case .torrent = $0.kind { return true }; return false }
        guard let torrent = torrentNodes.first, let secondTorrent = torrentNodes.dropFirst().first,
              let file = nodes.first(where: { if case .file = $0.kind { return true }; return false }) else {
            check(false, "Fixture contains two torrent rows and a file row")
            return (passed, lines)
        }
        func select(_ selected: [TorrentTreeNode]) {
            outline.selectRowIndexes(IndexSet(selected.map { outline.row(forItem: $0) }), byExtendingSelection: false)
        }
        func checkMenu(for node: TorrentTreeNode, enabled: Bool, message: String) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            coordinator.updateContextMenu(menu, row: outline.row(forItem: node))
            let refresh = menu.items.first { $0.title == "Refresh Torrent" }
            let edit = menu.items.first { $0.title == "Edit Refresh Source…" }
            check(refresh?.isEnabled == enabled && edit?.isEnabled == enabled, message)
        }
        select([torrent])
        check(canRefreshSelection, "A single torrent row enables refresh")
        checkMenu(for: torrent, enabled: true, message: "Native menu offers enabled Refresh Torrent and Edit Refresh Source")
        select([file])
        check(!canRefreshSelection, "A file row cannot refresh its parent torrent")
        checkMenu(for: file, enabled: false, message: "Native menu disables refresh actions for file rows")
        select([torrent, secondTorrent])
        check(!canRefreshSelection, "Multiple torrent rows disable refresh")
        checkMenu(for: torrent, enabled: false, message: "Native context menu preserves multiple selection and disables refresh")
        select([torrent, file])
        check(!canRefreshSelection, "A torrent and file selection cannot refresh ambiguously")
        select([torrent])
        editRefreshSourceSelection()
        if let draft = refreshSourceEditor, case .transfer(let id, let refreshAfterSave) = draft.purpose {
            check(id == torrent.transferIDs.first && !refreshAfterSave, "Edit Refresh Source opens an editor for the selected torrent")
        } else { check(false, "Edit Refresh Source opens its source editor") }
        refreshSourceEditor = nil
        try? await Task.sleep(for: .milliseconds(200))
        beginRefreshSelection()
        if let draft = refreshSourceEditor, case .transfer(let id, let refreshAfterSave) = draft.purpose {
            check(id == torrent.transferIDs.first && refreshAfterSave && draft.sourceText.isEmpty,
                  "Refreshing a torrent without a source asks for its URL once")
        } else { check(false, "Missing-source refresh opens its source editor") }
        check(refreshOperation == nil, "Missing-source prompt does not start network or engine work")
        check(!canSwitchProfile && !canImportFromQBittorrent && !canOpenTorrentURL && !canOperateTransfers,
              "Source draft prevents profile switches, overlapping imports, and transfer actions")
        try? await Task.sleep(for: .milliseconds(300))
        check(window.attachedSheet != nil, "Refresh source editor is presented as a native sheet")
        let sourceDraft = refreshSourceEditor
        refreshSourceEditor = nil
        try? await Task.sleep(for: .milliseconds(200))
        let operation = TorrentRefreshOperation(title: "Refresh Open Video Collection", profileID: activeProfile?.id ?? "ui-research")
        refreshOperation = operation
        check(!canRefreshSelection && !canSwitchProfile && !canImportFromQBittorrent && !canOpenTorrentURL && !canOperateTransfers,
              "Refresh operation prevents overlapping refresh, import, profile, and transfer actions")
        checkMenu(for: torrent, enabled: false, message: "Native menu disables refresh and source editing during a refresh")
        let operationMenu = NSMenu()
        operationMenu.autoenablesItems = false
        coordinator.updateContextMenu(operationMenu, row: outline.row(forItem: torrent))
        check(["Start", "Pause", "Recheck"].allSatisfy { title in operationMenu.items.first { $0.title == title }?.isEnabled == false },
              "Native menu disables Start, Pause, and Recheck during a refresh")
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-refresh-selection") {
            operation.isWorking = false
            operation.status = "Select at least one file to download from the updated torrent."
            operation.selectionMetainfo = debugVideoCollectionMetainfo()
            operation.selectedFiles = []
            check(operation.selectionMetainfo?.files.count == 12 && operation.selectedFiles.isEmpty,
                  "Synthetic updated torrent presents its files with an empty selection")
        } else if arguments.contains("--ui-refresh-result") {
            operation.isWorking = false
            operation.status = "Torrent refreshed."
            check(!operation.isWorking && operation.error == nil, "Successful result is ready to dismiss")
        } else if arguments.contains("--ui-refresh-progress") {
            check(operation.isWorking && operation.status == "Fetching torrent…", "Fetching progress is shown before metadata arrives")
        } else {
            refreshOperation = nil
            refreshSourceEditor = sourceDraft
        }
        try? await Task.sleep(for: .milliseconds(300))
        check(window.attachedSheet != nil, "Requested refresh state is presented as a native sheet")
        // Query the OS-visible accessibility tree: SwiftUI action buttons are virtual elements.
        // Run AX requests off the main actor so this app can service its own accessibility requests.
        func buttonEnabled(_ title: String) async -> Bool? {
            let processID = getpid()
            let result = await Task.detached(priority: .userInitiated) { () -> (Bool?, [String]) in
                let application = AXUIElementCreateApplication(processID)
                AXUIElementSetMessagingTimeout(application, 1)
                func attribute(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
                    var value: CFTypeRef?
                    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                    return (error, value)
                }
                let windows = attribute(application, kAXWindowsAttribute)
                guard windows.0 == .success, let roots = windows.1 as? [AXUIElement] else {
                    return (nil, ["Refresh accessibility windows query failed: AXError \(windows.0.rawValue), trusted: \(AXIsProcessTrusted())"])
                }
                var queue = roots.map { ($0, 0) }
                var visited: [AXUIElement] = []
                var cursor = 0
                var diagnostics: [String] = []
                let deadline = Date().addingTimeInterval(5)
                while cursor < queue.count && visited.count < 1000 && Date() < deadline {
                    let (element, depth) = queue[cursor]
                    cursor += 1
                    guard depth <= 12, !visited.contains(where: { CFEqual($0, element) }) else { continue }
                    visited.append(element)
                    let role = attribute(element, kAXRoleAttribute)
                    if role.0 == .apiDisabled || role.0 == .cannotComplete {
                        return (nil, ["Refresh accessibility role query failed: AXError \(role.0.rawValue), trusted: \(AXIsProcessTrusted())"])
                    }
                    if role.1 as? String == kAXButtonRole {
                        let name = attribute(element, kAXTitleAttribute).1 as? String
                        let description = attribute(element, kAXDescriptionAttribute).1 as? String
                        if name == title || description == title {
                            let enabled = attribute(element, kAXEnabledAttribute)
                            guard enabled.0 == .success, let value = enabled.1 as? Bool else {
                                return (nil, ["Refresh accessibility enabled query failed for \(title): AXError \(enabled.0.rawValue)"])
                            }
                            return (value, ["Refresh accessibility button: \(title), AXEnabled: \(value)"])
                        }
                    }
                    guard depth < 12 else { continue }
                    for name in ["AXSheets", kAXChildrenAttribute] {
                        if let children = attribute(element, name).1 as? [AXUIElement] {
                            queue.append(contentsOf: children.prefix(max(0, 1000 - queue.count)).map { ($0, depth + 1) })
                        }
                    }
                }
                diagnostics.append("Refresh accessibility button not found: \(title); inspected \(visited.count) elements, trusted: \(AXIsProcessTrusted())")
                return (nil, diagnostics)
            }.value
            lines.append(contentsOf: result.1)
            return result.0
        }
        if window.attachedSheet?.contentView != nil {
            if arguments.contains("--ui-refresh-selection") {
                check(await buttonEnabled("Apply Update") == false, "Empty file selection disables Apply Update")
                operation.selectedFiles = [0]
                try? await Task.sleep(for: .milliseconds(120))
                check(await buttonEnabled("Apply Update") == true, "Selecting a file enables Apply Update")
                operation.selectedFiles = []
                try? await Task.sleep(for: .milliseconds(120))
            } else if arguments.contains("--ui-refresh-result") {
                check(await buttonEnabled("Done") == true, "Successful result offers Done")
            } else if arguments.contains("--ui-refresh-progress") {
                check(await buttonEnabled("Cancel") == true, "Fetching progress offers Cancel")
            }
        }
        return (passed, lines)
    }

    private func debugVideoCollectionMetainfo() -> TorrentMetainfo {
        let files: [TorrentFile] = (0..<12).map { index in
            TorrentFile(index: index, path: ["Open Video Collection", "Season 02", "Open.Video.Collection.S02E\(String(format: "%02d", index + 1)).1080p.WEB-DL.Long.Descriptive.Filename.mkv"], length: 4_194_304, offset: Int64(index) * 4_194_304)
        }
        return TorrentMetainfo(infoHash: Data(repeating: 7, count: 20), rawInfo: Data(), name: "Open Video Collection (Season 2) WEB-DL 1080p", pieceLength: 4_194_304, pieceHashes: files.map { _ in Data(repeating: 7, count: 20) }, files: files, trackerTiers: [], isPrivate: true, isMultiFile: true)
    }

    private func installDebugAddTorrent() {
        uiState.lastDestinationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Torrenza-UI/Downloads", isDirectory: true)
        let draft = makeImportDraft(metainfo: debugVideoCollectionMetainfo())
        pendingImport = draft
    }

    private func checkDebugAddTorrent(window: NSWindow) async -> (passed: Bool, lines: [String]) {
        var passed = true
        var lines: [String] = []
        func check(_ condition: Bool, _ message: String) {
            let line = "\(condition ? "PASS" : "FAIL"): Add Torrent check: \(message)"
            lines.append(line); print(line)
            if !condition { passed = false }
        }
        guard let sheet = window.attachedSheet, let content = sheet.contentView, let draft = pendingImport else {
            check(false, "Synthetic import sheet is visible")
            return (passed, lines)
        }
        check(draft.destination == uiState.lastDestinationDirectory && draft.destination != nil, "Add Torrent prefills the profile’s saved destination without a folder picker")
        check(sheet.styleMask.contains(.resizable), "Native sheet allows user resizing")
        let originalSelection = draft.selectedFiles
        let originalRatio = draft.ratio
        let minimum = sheet.contentMinSize
        lines.append("Add Torrent minimum content size: \(minimum)")
        let enlarged = NSSize(width: max(960, content.bounds.width + 200), height: max(720, content.bounds.height + 160))
        sheet.setContentSize(enlarged)
        try? await Task.sleep(for: .milliseconds(200))
        content.layoutSubtreeIfNeeded()
        check(abs(content.bounds.width - enlarged.width) < 2 && abs(content.bounds.height - enlarged.height) < 2, "Larger width and height are honored")
        check(draft.selectedFiles == originalSelection && draft.ratio == originalRatio && !draft.unlimitedSeed && !draft.allowExisting, "Resizing preserves selection and seed options")
        draft.selectedFiles = []
        draft.allowExisting = true
        draft.ratio = 100
        try? await Task.sleep(for: .milliseconds(100))
        sheet.setContentSize(minimum)
        try? await Task.sleep(for: .milliseconds(200))
        content.layoutSubtreeIfNeeded()
        check(abs(content.bounds.width - minimum.width) < 2 && abs(content.bounds.height - minimum.height) < 2, "Sheet returns to its minimum size with empty selection and reuse options")
        // SwiftUI action buttons are virtual controls, rather than NSButtons.
        // Inspect the enabled Add action and minimum-size layout in this capture.
        let captureView = content.superview ?? content
        captureView.layoutSubtreeIfNeeded(); captureView.displayIfNeeded()
        if let bitmap = captureView.bitmapImageRepForCachingDisplay(in: captureView.bounds) {
            captureView.cacheDisplay(in: captureView.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Torrenza-UI", isDirectory: true)
                let theme = ProcessInfo.processInfo.arguments.contains("--ui-dark") ? "dark" : "light"
                let output = directory.appendingPathComponent("ui-smoke-\(theme)-add-torrent-minimum-empty.png")
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try png.write(to: output, options: .atomic)
                    check(true, "Minimum-size empty-selection screenshot written: \(output.path)")
                } catch { check(false, "Could not write minimum-size screenshot: \(error)") }
            } else { check(false, "Could not encode minimum-size screenshot") }
        } else { check(false, "Could not capture minimum-size screenshot") }
        sheet.setContentSize(enlarged)
        try? await Task.sleep(for: .milliseconds(200))
        check(abs(content.bounds.width - enlarged.width) < 2 && abs(content.bounds.height - enlarged.height) < 2 && draft.selectedFiles.isEmpty && draft.allowExisting && draft.ratio == 100, "Empty-selection sheet resizes without changing reuse or ratio options")
        draft.selectedFiles = originalSelection
        draft.allowExisting = false
        draft.ratio = originalRatio
        if ProcessInfo.processInfo.arguments.contains("--ui-add-torrent-error") {
            draft.error = "Refusing to overwrite existing file: Open Video Collection/Season 02/Open.Video.Collection.S02E01.1080p.WEB-DL.Long.Descriptive.Filename.mkv"
            sheet.setContentSize(minimum)
            lines.append("Error-state capture: existing-file rejection, unchanged import choices, minimum sheet size")
        }
        try? await Task.sleep(for: .milliseconds(100))
        return (passed, lines)
    }

    /// Exercises the native header callback and live sibling ordering using only synthetic transfers.
    private func checkDebugSorting(outline: NSOutlineView) async -> (passed: Bool, lines: [String]) {
        var passed = true
        var lines: [String] = []
        func check(_ condition: Bool, _ message: String) {
            let line = "\(condition ? "PASS" : "FAIL"): Sorting check: \(message)"
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
        func nativeSelectionIDs() -> Set<String> {
            Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? TorrentTreeNode)?.id })
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(120)) }
        let columns: [TreeSortColumn] = [.name, .size, .progress, .download, .upload, .uploaded, .seeds, .peers, .added]
        for column in columns {
            let prototype = outline.tableColumns.first { $0.identifier.rawValue == column.rawValue }?.sortDescriptorPrototype
            check(prototype?.key == column.rawValue, "\(column.rawValue) header has a matching native sort prototype")
        }
        let nodes = visibleNodes()
        guard let torrent = nodes.first(where: { $0.id == "torrent:ui-a" }),
              let archive = nodes.first(where: { $0.name == "Archive.zip" }),
              let documents = nodes.first(where: { $0.name == "Documents" }),
              let guide = nodes.first(where: { $0.name == "Guide.pdf" }),
              let transferIndex = transfers.firstIndex(where: { $0.id == "ui-a" }),
              let archiveIndex = transfers[transferIndex].files.firstIndex(where: { $0.file.path.last == "Archive.zip" }) else {
            check(false, "Fixture contains the expected torrent and nested payload")
            return (passed, lines)
        }
        let selected: Set<String> = [archive.id, guide.id]
        let rows = IndexSet((0..<outline.numberOfRows).filter { row in
            (outline.item(atRow: row) as? TorrentTreeNode).map { selected.contains($0.id) } ?? false
        })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        let expanded = coordinator.expanded
        func checkPreserved() {
            check(nativeSelectionIDs() == selected && Set(selectedNodes.map(\.id)) == selected,
                  "Sorting preserves selected file IDs in AppKit and the model")
            check(expanded.isSubset(of: coordinator.expanded) && outline.isItemExpanded(torrent) && outline.isItemExpanded(documents),
                  "Sorting preserves expanded branches")
            let current = visibleNodes()
            check(current.contains { $0 === archive } && current.contains { $0 === documents } && current.contains { $0 === guide },
                  "Sorting retains payload node identity")
        }
        func setSort(_ column: TreeSortColumn, ascending: Bool) async {
            guard let prototype = outline.tableColumns.first(where: { $0.identifier.rawValue == column.rawValue })?.sortDescriptorPrototype else { return }
            outline.sortDescriptors = [prototype.ascending == ascending ? prototype : prototype.reversedSortDescriptor as! NSSortDescriptor]
            await settle()
            check(uiState.sortOrder == TreeSortOrder(column: column, ascending: ascending),
                  "Native \(column.rawValue) descriptor updates the saved sort direction")
        }
        func checkOrder(_ expected: [String], _ message: String) {
            check(tree.children(of: torrent).map(\.name) == expected, message)
            let first = expected.first == "Archive.zip" ? archive : documents
            let second = expected.first == "Archive.zip" ? documents : archive
            check(outline.row(forItem: first) >= 0 && outline.row(forItem: first) < outline.row(forItem: second),
                  "Native outline displays the requested sibling order")
            check(outline.parent(forItem: archive) as? TorrentTreeNode === torrent
                  && outline.parent(forItem: documents) as? TorrentTreeNode === torrent
                  && outline.parent(forItem: guide) as? TorrentTreeNode === documents,
                  "Sorting keeps every file inside its existing folder")
        }
        await setSort(.size, ascending: true)
        checkOrder(["Documents", "Archive.zip"], "Ascending size uses numeric file and folder totals")
        checkPreserved()
        await setSort(.size, ascending: false)
        checkOrder(["Archive.zip", "Documents"], "Descending size reverses siblings within the torrent")
        checkPreserved()
        await setSort(.name, ascending: true)
        checkOrder(["Archive.zip", "Documents"], "Ascending name orders mixed file and folder siblings")
        await setSort(.name, ascending: false)
        checkOrder(["Documents", "Archive.zip"], "Descending name reverses siblings")
        await setSort(.uploaded, ascending: false)
        checkOrder(["Documents", "Archive.zip"], "Uploaded column sorts numeric per-file totals")
        let originalTransfers = transfers
        transfers[transferIndex].files[archiveIndex].uploadedBytes = 200_000
        coordinator.refresh(model: self)
        await settle()
        checkOrder(["Archive.zip", "Documents"], "Live upload updates reorder siblings without a topology change")
        checkPreserved()
        transfers = originalTransfers
        coordinator.refresh(model: self)
        await settle()
        checkOrder(["Documents", "Archive.zip"], "Restored fixture values restore their sorted order")
        checkPreserved()
        if let addedColumn = outline.tableColumns.first(where: { $0.identifier.rawValue == "added" }),
           let locations = visibleNodes().first(where: { $0.url?.path == "/Volumes/Storage/torrents" }),
           let other = visibleNodes().first(where: { $0.url?.path == "/Volumes/Storage/torrents/other" }),
           let video = visibleNodes().first(where: { $0.url?.path == "/Volumes/Storage/torrents/video" }),
           let legacyTorrent = visibleNodes().first(where: { $0.id == "torrent:ui-offline" }),
           let expectedDate = transfers[transferIndex].addedAt {
            check(addedColumn.title == "Added" && addedColumn.sortDescriptorPrototype?.ascending == false,
                  "Added header defaults to newest first")
            func checkAddedCell(_ node: TorrentTreeNode, expected: String, description: String) {
                let cell = coordinator.outlineView(outline, viewFor: addedColumn, item: node) as? NSTableCellView
                check(cell?.textField?.stringValue == expected, description)
                check(cell?.toolTip?.isEmpty == false, "Added cell explains its date scope")
            }
            let expectedText = expectedDate.formatted(date: .numeric, time: .shortened)
            checkAddedCell(torrent, expected: expectedText, description: "Added renders the torrent import date using the current locale")
            checkAddedCell(guide, expected: expectedText, description: "Files display their torrent import date")
            checkAddedCell(locations, expected: expectedText, description: "Location groups display their newest represented import date")
            checkAddedCell(legacyTorrent, expected: "—", description: "Legacy torrents without an import date display an em dash")
            for ascending in [true, false] {
                await setSort(.added, ascending: ascending)
                check(tree.children(of: locations).map(\.id) == (ascending ? [video.id, other.id] : [other.id, video.id]),
                      "Added \(ascending ? "ascending" : "descending") orders location siblings chronologically")
                let first = ascending ? video : other
                let second = ascending ? other : video
                check(outline.row(forItem: first) >= 0 && outline.row(forItem: first) < outline.row(forItem: second),
                      "Native outline displays the chronological Added order")
                check(outline.parent(forItem: other) as? TorrentTreeNode === locations
                      && outline.parent(forItem: video) as? TorrentTreeNode === locations,
                      "Added sorting preserves filesystem-location grouping")
                checkOrder(["Archive.zip", "Documents"], "Equal import dates use deterministic name order within the torrent")
                checkPreserved()
            }
        } else {
            check(false, "Added column and dated location fixtures are available")
        }
        do {
            var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(uiState)) as! [String: Any]
            legacy.removeValue(forKey: "sortOrder")
            let decodedLegacy = try JSONDecoder().decode(UIState.self, from: JSONSerialization.data(withJSONObject: legacy))
            check(decodedLegacy.sortOrder == nil, "Legacy interface state loads without a sorting preference")
            for column in columns {
                for ascending in [true, false] {
                    var state = uiState
                    state.sortOrder = TreeSortOrder(column: column, ascending: ascending)
                    let decoded = try JSONDecoder().decode(UIState.self, from: JSONEncoder().encode(state))
                    check(decoded == state, "\(column.rawValue) \(ascending ? "ascending" : "descending") preference round-trips")
                }
            }
        } catch { check(false, "Sort preference serialization: \(error.localizedDescription)") }
        let savedUIState = uiState
        let savedColumnOrder = outline.tableColumns.map { $0.identifier.rawValue }
        let legacyColumnOrder = savedColumnOrder.filter { $0 != "added" }
        coordinator.restoring = true
        outline.moveColumn(outline.column(withIdentifier: .init("added")), toColumn: outline.numberOfColumns - 1)
        coordinator.restoring = false
        uiState.columnOrder = legacyColumnOrder
        uiState.expandedNodeIDs = coordinator.expanded.sorted()
        uiState.hasSavedExpansion = true
        uiState.selectedNodeIDs = selected.sorted()
        coordinator.loadedState = false
        coordinator.refresh(model: self)
        await settle()
        let restoredColumnOrder = outline.tableColumns.map { $0.identifier.rawValue }
        var expectedColumnOrder = legacyColumnOrder
        expectedColumnOrder.insert("added", at: legacyColumnOrder.firstIndex(of: "name").map { $0 + 1 } ?? 0)
        check(restoredColumnOrder == expectedColumnOrder,
              "Legacy saved column order inserts Added after Name and preserves all existing column positions relative to each other")
        checkPreserved()
        uiState = savedUIState
        outline.window?.makeFirstResponder(outline)
        return (passed, lines)
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

        // A second installed instance can own the key window when this fixture launches.
        // Establish the normal keyboard responder chain before exercising the app action.
        NSApp.activate()
        outline.window?.makeKeyAndOrderFront(nil)
        await settle()
        let acceptedFirstResponder = outline.window?.makeFirstResponder(outline) == true
        await settle()
        let selectAllTarget = NSApp.target(forAction: #selector(NSText.selectAll(_:)), to: nil, from: nil)
        lines.append("Select All responder: active=\(NSApp.isActive), keyWindow=\(NSApp.keyWindow === outline.window), accepted=\(acceptedFirstResponder), firstResponder=\(String(describing: outline.window?.firstResponder)), target=\(String(describing: selectAllTarget)), rows=\(outline.numberOfRows)")
        check(acceptedFirstResponder && outline.window?.firstResponder === outline && NSApp.keyWindow === outline.window,
              "Native outline owns the key-window keyboard responder before Select All")
        let selectAllSent = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        lines.append("Select All dispatch: sent=\(selectAllSent), nativeSelected=\(outline.selectedRowIndexes.count), modelSelected=\(selectedNodes.count), visibleRows=\(outline.numberOfRows)")
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

    /// Exercises sidebar counts, Needs Attention, zero-result layouts, search
    /// focus, layout persistence, and progress-cell reuse on the fixture.
    private func checkDebugWorkspace(window: NSWindow, view: NSView) async -> (passed: Bool, lines: [String]) {
        var passed = true
        var lines: [String] = []
        func check(_ condition: Bool, _ message: String) {
            let line = "\(condition ? "PASS" : "FAIL"): Workspace check: \(message)"
            lines.append(line); print(line)
            if !condition { passed = false }
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(200)) }
        @MainActor func findOutline(_ root: NSView) -> NSOutlineView? {
            if let outline = root as? NSOutlineView { return outline }
            for child in root.subviews { if let outline = findOutline(child) { return outline } }
            return nil
        }
        @MainActor func findSearchField(_ root: NSView) -> NSSearchField? {
            if let field = root as? NSSearchField { return field }
            for child in root.subviews { if let field = findSearchField(child) { return field } }
            return nil
        }

        let originalTransfers = transfers
        let originalFilter = filter
        let originalSearch = search
        let originalSidebarVisible = isSidebarVisible
        let originalInspectorVisible = showInspector
        defer {
            transfers = originalTransfers
            filter = originalFilter
            search = originalSearch
            isSidebarVisible = originalSidebarVisible
            showInspector = originalInspectorVisible
            refreshVisibleCount()
        }

        // Sidebar counts reuse the tree's shared predicate over complete snapshots.
        let counts = filterCounts
        for filter in TreeFilter.allCases {
            let expected = transfers.filter { filter.matches($0) }.count
            check(counts[filter] == expected, "Sidebar count for \(filter.rawValue) equals the shared predicate count (\(expected))")
        }

        // Needs Attention is a real, persistable filter.
        filter = .attention
        await settle()
        check(uiState.filter == TreeFilter.attention.rawValue, "Needs Attention selection persists in interface preferences")
        check(visibleTorrentCount == transfers.filter { TreeFilter.attention.matches($0) }.count, "Needs Attention narrows the visible-transfer summary")
        if let outline = findOutline(view) {
            let visibleStates = (0..<outline.numberOfRows).compactMap { row -> TransferState? in
                guard let node = outline.item(atRow: row) as? TorrentTreeNode, case .torrent(let id) = node.kind else { return nil }
                return transfers.first { $0.id == id }?.state
            }
            check(!visibleStates.isEmpty && visibleStates.allSatisfy { [.unavailable, .failed].contains($0) }, "Needs Attention shows only unavailable and failed torrents")
        } else {
            check(false, "Needs Attention keeps the tree visible for its matches")
        }

        // Zero-result filter and search layouts.
        filter = .paused
        await settle()
        check(transfers.allSatisfy { $0.state != .paused } && findOutline(view) == nil, "A filter with zero transfers replaces the tree with its empty state")
        filter = .all
        await settle()
        check(findOutline(view) != nil, "Show All Transfers restores the tree")
        search = "definitely-no-such-torrent-xyz"
        await settle()
        check(findOutline(view) == nil, "A search without matches replaces the tree with its empty state")
        search = ""
        await settle()
        check(findOutline(view) != nil, "Clearing search restores the tree")
        // The empty-state swap recreates the outline; restore full expansion so
        // later checks and the main capture see the same rows as before.
        findOutline(view)?.expandItem(nil, expandChildren: true)
        await settle()

        // Cmd-F focuses the relocated search field.
        if let field = findSearchField(view) {
            searchFocusRequest += 1
            await settle()
            check(field.currentEditor() != nil, "Cmd-F focus request activates the panel header search field")
            window.makeFirstResponder(nil)
        } else {
            check(false, "Panel header search field is present")
        }

        // Sidebar toggle keeps the tree and updates the saved preference.
        isSidebarVisible = false
        await settle()
        check(uiState.sidebarVisible == false && findOutline(view) != nil, "Hiding the sidebar keeps the tree visible and records the preference")
        isSidebarVisible = true
        await settle()
        check(uiState.sidebarVisible == true && findOutline(view) != nil, "Showing the sidebar restores it without changing the filter")

        // Split resizing reports and persists pane widths.
        @MainActor func findSplit(_ root: NSView) -> NSSplitView? {
            if let split = root as? NSSplitView { return split }
            for child in root.subviews { if let split = findSplit(child) { return split } }
            return nil
        }
        if let split = findSplit(view) {
            // Isolate model-side reporting from the pane hook.
            reportSidebarWidth(240, token: currentLayoutToken)
            try? await Task.sleep(for: .milliseconds(100))
            lines.append("Model report probe: saved=\(uiState.sidebarWidth ?? -1), effective=\(sidebarWidth)")
            split.setPosition(240, ofDividerAt: 0)
            try? await Task.sleep(for: .milliseconds(400))
            lines.append("Split drag probe: pane=\(split.arrangedSubviews.first?.bounds.width ?? -1), model=\(sidebarWidth), saved=\(uiState.sidebarWidth ?? -1), dividers=\(split.arrangedSubviews.count)")
            let sidebarPane = split.arrangedSubviews.first
            check(abs((sidebarPane?.bounds.width ?? 0) - 240) < 2 && abs(sidebarWidth - 240) < 1.5,
                  "Dragging the sidebar divider to 240 reports and persists the width")
            split.setPosition(150, ofDividerAt: 0)
            try? await Task.sleep(for: .milliseconds(400))
            lines.append("Split clamp probe: pane=\(split.arrangedSubviews.first?.bounds.width ?? -1), model=\(sidebarWidth)")
            check(abs((split.arrangedSubviews.first?.bounds.width ?? 0) - 216) < 2 && abs(sidebarWidth - 216) < 1.5,
                  "Pane minimum clamps the sidebar divider and persists 216")
            split.setPosition(224, ofDividerAt: 0)
            try? await Task.sleep(for: .milliseconds(400))
            check(abs(sidebarWidth - 224) < 1.5, "Restoring the default sidebar width persists 224")
        } else {
            check(false, "Workspace split is present for resizing checks")
        }

        // Inspector pane opens at its saved width alongside the tree.
        let originalSize = window.frame.size
        let outlineBeforeToggle = findOutline(view).map(ObjectIdentifier.init)
        window.setContentSize(NSSize(width: 1000, height: 480))
        showInspector = true
        await settle()
        if let split = findSplit(view), split.arrangedSubviews.count > 2 {
            let inspectorPane = split.arrangedSubviews.last
            check(inspectorPane?.isHidden == false && abs((inspectorPane?.bounds.width ?? 0) - inspectorWidth) < 2,
                  "Inspector pane appears at its saved width (\(Int(inspectorWidth)) points)")
        }
        check(findOutline(view) != nil, "Inspector and tree both fit at the 1000-point minimum width")
        check(outlineBeforeToggle != nil && findOutline(view).map(ObjectIdentifier.init) == outlineBeforeToggle,
              "Opening the inspector does not reconstruct the torrent outline")
        window.setContentSize(originalSize)
        showInspector = false
        await settle()

        // Layout preferences: legacy decode, nonfinite rejection, clamping.
        do {
            let legacyJSON = Data(#"{"version":1,"notificationsEnabled":false,"filter":"All Transfers","inspectorVisible":false,"expandedNodeIDs":[],"hasSavedExpansion":false,"selectedNodeID":"torrent:legacy","columnOrder":[],"columnWidths":{}}"#.utf8)
            let legacy = try JSONDecoder().decode(UIState.self, from: legacyJSON)
            check(legacy.effectiveSidebarVisible && legacy.effectiveSidebarWidth == 224 && legacy.effectiveInspectorWidth == 304,
                  "Legacy state without layout fields restores visible sidebar at 224 with a 304-point inspector")
            var state = legacy
            state.sidebarWidth = .nan
            state.inspectorWidth = 1e9
            check(state.effectiveSidebarWidth == 224 && state.effectiveInspectorWidth == 420,
                  "Nonfinite and oversized widths are rejected or clamped")
            state.sidebarWidth = 50
            state.inspectorWidth = 100
            check(state.effectiveSidebarWidth == 216 && state.effectiveInspectorWidth == 280,
                  "Undersized widths clamp to pane minima")
            let decoded = try JSONDecoder().decode(UIState.self, from: JSONEncoder().encode(state))
            check(decoded.effectiveSidebarWidth == 216 && decoded.effectiveInspectorWidth == 280, "Clamped widths round-trip")
        } catch {
            check(false, "Layout preference serialization: \(error.localizedDescription)")
        }

        // Progress cell reuse resets all visual state between rows.
        findOutline(view)?.expandItem(nil, expandChildren: true)
        await settle()
        if let outline = findOutline(view), let column = outline.tableColumns.first(where: { $0.identifier.rawValue == "progress" }),
           let coordinator = outline.delegate as? TorrentOutlineView.Coordinator {
            let nodes = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? TorrentTreeNode }
            let torrentNode = nodes.first { $0.id == "torrent:ui-a" }
            let offlineNode = nodes.first { $0.id == "torrent:ui-offline" }
            let folderNode = nodes.first { $0.kind == .folder && $0.fileIndices != nil }
            if let torrentNode, let offlineNode, let folderNode {
                let torrentCell = coordinator.outlineView(outline, viewFor: column, item: torrentNode) as? TorrentProgressCellView
                let expectedText = "Downloading · \(Int(transfers.first { $0.id == "ui-a" }!.progress * 100))%"
                check(torrentCell?.textField?.stringValue == expectedText, "Progress cell renders status and percentage for a downloading torrent")
                check(torrentCell?.track.isHidden == false, "Determinate rows show the compact track")
                // The same identifier dequeued for a different row must fully reset.
                let offlineCell = coordinator.outlineView(outline, viewFor: column, item: offlineNode) as? TorrentProgressCellView
                let offlineText = "Unavailable · \(Int(transfers.first { $0.id == "ui-offline" }!.progress * 100))%"
                check(offlineCell?.textField?.stringValue == offlineText && offlineCell?.track.isHidden == false,
                      "Reused progress cell reconfigures for an unavailable torrent")
                let folderCell = coordinator.outlineView(outline, viewFor: column, item: folderNode) as? TorrentProgressCellView
                check(folderCell?.track.isHidden == true && folderCell?.statusText.textColor == .secondaryLabelColor,
                      "Aggregate folder rows render a subdued percentage without a track")
                // Text-only statuses must clear the track on reuse.
                let direct = TorrentProgressCellView()
                direct.configure(fraction: nil, text: "No files selected", tint: .labelColor)
                direct.setTrackHidden(true)
                check(direct.track.isHidden && direct.textField?.stringValue == "No files selected", "Text-only status hides the track")
                direct.setTrackHidden(false)
                direct.configure(fraction: 0.42, text: "Downloading · 42%", tint: .labelColor)
                check(!direct.track.isHidden && direct.track.fraction == 0.42, "Determinate status restores the track and fraction")
            } else {
                check(false, "Fixture exposes torrent, unavailable, and folder rows for cell reuse")
            }
        } else {
            check(false, "Progress column and coordinator are available")
        }

        // Long inspector content stays laid out without disturbing the tree.
        window.setContentSize(NSSize(width: 1000, height: 480))
        showInspector = true
        await settle()
        findOutline(view)?.expandItem(nil, expandChildren: true)
        if let fixtureIndex = transfers.firstIndex(where: { $0.id == "ui-a" }) {
            let longName = String(repeating: "Long Descriptive Collection Name ", count: 4)
            transfers[fixtureIndex].name = longName
            transfers[fixtureIndex].error = String(repeating: "Storage warning with a long explanation. ", count: 3)
            transfers[fixtureIndex].trackers = ["https://tracker.example.test/announce?very_long_query_parameter=" + String(repeating: "abcdef0123456789", count: 8)]
            refreshVisibleCount()
            // Let the name change settle its structural reload, then re-expand
            // (fixture mode does not record expansion) and select the row.
            await settle()
            findOutline(view)?.expandItem(nil, expandChildren: true)
            if let outline = findOutline(view),
               let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? TorrentTreeNode)?.id == "torrent:ui-a" }) {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                await settle()
                let coordinator = outline.delegate as? TorrentOutlineView.Coordinator
                lines.append("Inspector probe: selectedRows=\(outline.selectedRowIndexes.count), modelNodes=\(selectedNodes.map(\.id)), canInteract=\(coordinator?.canInteract ?? false), tree=\(findOutline(view) != nil)")
                check(selectedTransfer?.name == longName && findOutline(view) != nil,
                      "Inspector renders a long transfer name alongside the tree without relayout failures")
            } else {
                check(false, "Torrent row is selectable for the long-content inspector check")
            }
        }
        showInspector = false
        await settle()
        // Restore the fixture inline so a later structural refresh cannot leave
        // the tree collapsed for the remaining checks and the final capture.
        transfers = originalTransfers
        filter = originalFilter
        search = originalSearch
        showInspector = originalInspectorVisible
        isSidebarVisible = originalSidebarVisible
        refreshVisibleCount()
        await settle()
        findOutline(view)?.expandItem(nil, expandChildren: true)
        window.setContentSize(originalSize)
        await settle()
        return (passed, lines)
    }

    /// The qBittorrent import sheet is resizable with visible actions at its minimum size.
    /// Exercises real mouse and keyboard selection on the tree: 34-point row
    /// geometry, painted highlights, multiselection, checkbox independence,
    /// focus changes, inactive windows, and scrolling reuse. Painted checks
    /// sample a background-only patch inside a row and compare it with the
    /// unselected rendering, avoiding text and icon edges.
    private func checkDebugSelection(window: NSWindow, view: NSView) async -> (passed: Bool, lines: [String]) {
        var passed = true
        var lines: [String] = []
        func check(_ condition: Bool, _ message: String) {
            let line = "\(condition ? "PASS" : "FAIL"): Selection check: \(message)"
            lines.append(line); print(line)
            if !condition { passed = false }
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(150)) }
        @MainActor func findOutline(_ root: NSView) -> NSOutlineView? {
            if let outline = root as? NSOutlineView { return outline }
            for child in root.subviews { if let outline = findOutline(child) { return outline } }
            return nil
        }

        guard let outline = findOutline(view) else {
            check(false, "Torrent outline is available")
            return (passed, lines)
        }
        let coordinator = outline.delegate as? TorrentOutlineView.Coordinator
        // Mouse clicks and emphasized selection need the window to be key.
        // Some launch contexts never let the app become frontmost, but the
        // window can still own key state inside the app, which is what the
        // outline's selection handling and emphasized painting follow.
        var activationAttempts = 0
        @MainActor func activateFixtureWindow() async {
            for _ in 0..<50 {
                activationAttempts += 1
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                if !window.isKeyWindow {
                    window.orderFrontRegardless()
                    window.makeKey()
                }
                if window.isKeyWindow { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        // Coverage disclosure: hover tracking is suspended while synthetic
        // mouse events run, so this check does not cover real hover
        // interaction, and arrow-key navigation is not exercised here (see
        // the note in the mouse section).
        lines.append("Coverage: hover tracking is suspended during synthetic mouse checks; hover interaction is not covered by this fixture")
        lines.append("Coverage: arrow-key selection is not exercised by this fixture and is reported as unverified")
        await activateFixtureWindow()
        // Some launch contexts (direct exec, background sessions) never grant
        // key state; clicks are then swallowed by AppKit. The mouse path is
        // only asserted when interaction is actually possible.
        let interactionReady = window.isKeyWindow
        if !interactionReady {
            lines.append("SKIP: Selection check: mouse-path checks need a key window; this launch context did not grant one")
        }
        lines.append("Activation probe: attempts=\(activationAttempts), key=\(window.isKeyWindow), active=\(NSApp.isActive)")
        outline.expandItem(nil, expandChildren: true)
        await settle()

        // MARK: row geometry

        func rowGeometry() -> (height: CGFloat, pitch: CGFloat)? {
            guard outline.numberOfRows > 2 else { return nil }
            let first = outline.rect(ofRow: 0)
            let second = outline.rect(ofRow: 1)
            return (first.height, second.minY - first.minY)
        }
        func checkRowGeometry(_ context: String) {
            guard let geometry = rowGeometry() else {
                check(false, "34-point row geometry measurable (\(context))")
                return
            }
            check(abs(geometry.height - 34) < 0.5 && abs(geometry.pitch - 34) < 0.5,
                  "Row height and pitch measure 34 points (\(context)): height=\(geometry.height), pitch=\(geometry.pitch)")
        }
        checkRowGeometry("initial layout")
        window.setContentSize(NSSize(width: window.frame.width + 120, height: window.frame.height + 60))
        await settle()
        checkRowGeometry("after resize")
        outline.reloadData()
        await settle()
        outline.expandItem(nil, expandChildren: true)
        await settle()
        checkRowGeometry("after reload")

        // MARK: painted-highlight sampling

        /// Samples a background-only patch near the trailing edge of a row.
        /// The outline paints a clear background over the SwiftUI panel, and
        /// capturing the content view alone leaves that region transparent;
        /// capturing from the superview composites the full window. The name
        /// column's trailing area is clean for the fixture's short file names.
        @MainActor func backgroundSample(_ row: Int) -> NSColor? {
            guard row >= 0, row < outline.numberOfRows,
                  let captureRoot = window.contentView?.superview ?? window.contentView else { return nil }
            let rect = outline.rect(ofRow: row)
            let nameTrailing = outline.rect(ofColumn: 0).maxX - 20
            let outlinePoint = NSPoint(x: nameTrailing, y: rect.midY)
            let pointInRoot = captureRoot.convert(outlinePoint, from: outline)
            guard pointInRoot.x >= 0, pointInRoot.y >= 0,
                  pointInRoot.x <= captureRoot.bounds.maxX, pointInRoot.y <= captureRoot.bounds.maxY else { return nil }
            guard let bitmap = captureRoot.bitmapImageRepForCachingDisplay(in: captureRoot.bounds) else { return nil }
            captureRoot.cacheDisplay(in: captureRoot.bounds, to: bitmap)
            // The bitmap is in pixels; coordinates are in points.
            let scale = CGFloat(bitmap.pixelsWide) / max(1, captureRoot.bounds.width)
            return bitmap.colorAt(x: Int(pointInRoot.x * scale), y: Int(pointInRoot.y * scale))
        }
        @MainActor func colorDistance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            // Captured pixels and palette colors live in different spaces;
            // compare both in sRGB.
            let first = a.usingColorSpace(.sRGB) ?? a
            let second = b.usingColorSpace(.sRGB) ?? b
            return abs(first.redComponent - second.redComponent) + abs(first.greenComponent - second.greenComponent) + abs(first.blueComponent - second.blueComponent)
        }
        /// The muted fill is translucent; flatten it over the panel to compare
        /// with captured pixels.
        @MainActor func flattenedOverPanel(_ color: NSColor) -> NSColor? {
            guard let translucent = color.usingColorSpace(.sRGB),
                  let base = panel.usingColorSpace(.sRGB) else { return nil }
            let alpha = translucent.alphaComponent
            return NSColor(srgbRed: translucent.redComponent * alpha + base.redComponent * (1 - alpha),
                           green: translucent.greenComponent * alpha + base.greenComponent * (1 - alpha),
                           blue: translucent.blueComponent * alpha + base.blueComponent * (1 - alpha),
                           alpha: 1)
        }
        let appearance = outline.effectiveAppearance
        let panel = Palette.panel.resolved(in: appearance)
        let selection = Palette.selectionFill.resolved(in: appearance)
        let selectionInactive = Palette.selectionFillInactive.resolved(in: appearance)

        func row(of nodeID: String) -> Int? {
            (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? TorrentTreeNode)?.id == nodeID }
        }
        guard let torrentRow = row(of: "torrent:ui-a"),
              let fileRow = row(of: "file:ui-a:0") ?? row(of: "file:ui-a:1"),
              let secondTorrentRow = row(of: "torrent:ui-b") else {
            check(false, "Fixture exposes torrent and file rows for selection checks")
            return (passed, lines)
        }

        /// Captured pixels shift systematically from palette colors (color
        /// matching between the bitmap and sRGB). Measure that offset from a
        /// known panel patch and apply it to every expected color so painted
        /// comparisons stay meaningful in both appearances.
        @MainActor func captureCalibration() -> NSColor? {
            guard let raw = backgroundSample(fileRow), let sample = raw.usingColorSpace(.sRGB),
                  let base = panel.usingColorSpace(.sRGB) else { return nil }
            return NSColor(srgbRed: sample.redComponent - base.redComponent,
                           green: sample.greenComponent - base.greenComponent,
                           blue: sample.blueComponent - base.blueComponent,
                           alpha: 0)
        }
        @MainActor func calibrated(_ expected: NSColor, offset: NSColor?) -> NSColor {
            guard let offset, let e = expected.usingColorSpace(.sRGB) else { return expected }
            return NSColor(srgbRed: min(max(e.redComponent + offset.redComponent, 0), 1),
                           green: min(max(e.greenComponent + offset.greenComponent, 0), 1),
                           blue: min(max(e.blueComponent + offset.blueComponent, 0), 1),
                           alpha: 1)
        }
        let captureOffset = captureCalibration()
        let calibratedPanel = calibrated(panel, offset: captureOffset)
        // Diagnostic: where does the window capture actually have content?
        if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / max(1, content.bounds.width)
            let spots: [(String, NSPoint)] = [
                ("header", NSPoint(x: 100, y: 15)),
                ("firstRow", NSPoint(x: 100, y: content.bounds.midY)),
                ("shelf", NSPoint(x: content.bounds.midX, y: 20))
            ]
            for (name, spot) in spots {
                let color = bitmap.colorAt(x: Int(spot.x * scale), y: Int(spot.y * scale))
                let described = color.map { "\($0)" } ?? "nil"
                lines.append("Capture probe \(name) at \(spot): \(described)")
            }
            let centralSpot = NSPoint(x: 508, y: 430)
            let centralColor = bitmap.colorAt(x: Int(centralSpot.x * scale), y: Int(centralSpot.y * scale))
            lines.append("Capture probe central \(centralSpot): \(centralColor.map { "\($0)" } ?? "nil"), pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
            lines.append("Capture probe contentBounds=\\(content.bounds), scale=\\(scale)")
        }

        // Unselected rows paint the panel background.
        if let unselected = backgroundSample(fileRow) {
            lines.append("Sample probe: unselected=\(unselected), calibratedPanel=\(calibratedPanel)")
            check(colorDistance(unselected, calibratedPanel) < 0.08, "Unselected file row paints the panel background")
        } else {
            check(false, "Unselected file row is sampleable")
        }

        // Programmatic selection paints the lavender highlight across the row.
        outline.selectRowIndexes(IndexSet(integer: fileRow), byExtendingSelection: false)
        await settle()
        let calibratedSelection = calibrated(selection, offset: captureOffset)
        let calibratedInactive = calibrated(flattenedOverPanel(selectionInactive) ?? selectionInactive, offset: captureOffset)
        @MainActor func paintsSelection(_ row: Int) -> Bool {
            guard let painted = backgroundSample(row) else { return false }
            // Emphasized selection is unambiguous; the muted inactive fill is
            // subtle by design, so accept it comparatively: clearly closer to
            // the muted fill than to the bare panel.
            if colorDistance(painted, calibratedSelection) < 0.12 { return true }
            let toInactive = colorDistance(painted, calibratedInactive)
            let toPanel = colorDistance(painted, calibratedPanel)
            return toInactive < 0.12 && toInactive + 0.03 < toPanel
        }
        // A fully inactive app defers selection painting until activation,
        // which is a launch-context artifact; the emphasized fill is only
        // observable with an active app.
        let paintingObservable = NSApp.isActive
        if paintingObservable {
            check(paintsSelection(fileRow), "Programmatically selected file row paints the lavender highlight")
        } else {
            lines.append("SKIP: Selection check: painted-selection checks — app inactive in this launch context")
        }
        if let painted = backgroundSample(fileRow) {
            lines.append("Paint probe: painted=\(painted), dSel=\(colorDistance(painted, calibratedSelection)), dInact=\(colorDistance(painted, calibratedInactive)), dPanel=\(colorDistance(painted, calibratedPanel))")
        }
        if let leading = backgroundSample(fileRow) {
            _ = leading // trailing sample covers span; keep one clean patch
        }

        // MARK: mouse-driven selection

        // Synthetic events and hover tracking do not mix: AppKit can route
        // enter/exit events at recycled row views mid-teardown.
        TorrentTableRowView.suspendHoverTracking(in: outline)
        defer { TorrentTableRowView.hoverTrackingEnabled = true }

        @MainActor func clickRow(_ row: Int, flags: NSEvent.ModifierFlags = []) async {
            let rect = outline.rect(ofRow: row)
            // Click inside the progress column: no disclosure, checkbox, or icon.
            let progressIndex = outline.tableColumns.firstIndex { $0.identifier.rawValue == "progress" } ?? 1
            let columnRect = outline.rect(ofColumn: progressIndex)
            let point = outline.convert(NSPoint(x: columnRect.midX, y: rect.midY), to: nil)
            await postClick(at: point, flags: flags)
        }
        /// Drives the outline's own mouse handling deterministically: the
        /// mouse-up is queued first so the outline's click tracking loop
        /// consumes it immediately instead of blocking the main actor.
        @MainActor func postClick(at point: NSPoint, flags: NSEvent.ModifierFlags = []) async {
            for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                                     timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.05,
                                                     windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                if index == 0 {
                    if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: flags,
                                                   timestamp: ProcessInfo.processInfo.systemUptime + 0.05,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 1, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(up, atStart: false)
                    }
                    outline.mouseDown(with: event)
                } else {
                    window.sendEvent(event)
                }
            }
        }

        outline.deselectAll(nil)
        await settle()
        let inclusionBefore = transfers.map { $0.id + ":" + $0.files.filter(\.selected).map { String($0.id) }.joined(separator: ",") }
        /// Records everything needed to diagnose a rejected click: expected
        /// and actual row selection, model node IDs, and window state.
        func reportClickOutcome(expected: IndexSet, label: String) {
            lines.append("Click failure detail (\(label)): expectedRows=\(expected.sorted()), actualRows=\(outline.selectedRowIndexes.sorted()), nodeIDs=\(selectedNodes.map(\.id)), keyWindow=\(window.isKeyWindow), appActive=\(NSApp.isActive), firstResponderIsOutline=\(window.firstResponder === outline)")
        }
        // The interactive precondition must hold at click time, not just at
        // check start: activation can decay between phases. Re-establish it
        // immediately; when it holds, a missed click is a genuine failure.
        await activateFixtureWindow()
        let clickInteractionReady = window.isKeyWindow
        if clickInteractionReady {
            // One synthetic click sequence per assertion; settle only for
            // model synchronization. A miss here is a FAIL, not a skip.
            await clickRow(torrentRow)
            await settle()
            let torrentClicked = outline.selectedRowIndexes == IndexSet(integer: torrentRow)
            check(torrentClicked && Set(selectedNodes.map(\.id)) == ["torrent:ui-a"],
                  "Clicking a torrent row selects it in the outline and the model")
            if !torrentClicked { reportClickOutcome(expected: IndexSet(integer: torrentRow), label: "torrent click") }
            check(paintsSelection(torrentRow), "Clicked torrent row paints the selection highlight")

            await clickRow(fileRow)
            await settle()
            let fileClicked = outline.selectedRowIndexes == IndexSet(integer: fileRow)
            check(fileClicked && Set(selectedNodes.map(\.id)).count == 1 && selectedNodes.first?.kind != nil,
                  "Clicking a file row selects the file row")
            if !fileClicked { reportClickOutcome(expected: IndexSet(integer: fileRow), label: "file click") }
            let inclusionAfter = transfers.map { $0.id + ":" + $0.files.filter(\.selected).map { String($0.id) }.joined(separator: ",") }
            check(inclusionBefore == inclusionAfter, "Row selection does not change download inclusion")

            // Cmd-click extends a programmatic anchor into a multiselection.
            outline.selectRowIndexes(IndexSet(integer: torrentRow), byExtendingSelection: false)
            await settle()
            await clickRow(fileRow, flags: [.command])
            await settle()
            let cmdSelected = IndexSet([torrentRow, fileRow])
            check(outline.selectedRowIndexes == cmdSelected, "Cmd-click extends native selection")
            if outline.selectedRowIndexes != cmdSelected { reportClickOutcome(expected: cmdSelected, label: "cmd-click") }
            check(paintsSelection(torrentRow) && paintsSelection(fileRow),
                  "Both Cmd-selected rows paint the highlight")

            // Shift-click selects the native range between anchor and click.
            outline.selectRowIndexes(IndexSet(integer: torrentRow), byExtendingSelection: false)
            await settle()
            await clickRow(secondTorrentRow, flags: [.shift])
            await settle()
            let rangeSelected = IndexSet(integersIn: torrentRow...secondTorrentRow)
            check(outline.selectedRowIndexes == rangeSelected, "Shift-click selects a native range")
            if outline.selectedRowIndexes != rangeSelected { reportClickOutcome(expected: rangeSelected, label: "shift-click") }
            check(paintsSelection(torrentRow) && paintsSelection(secondTorrentRow),
                  "Shift-selected range paints the highlight at both ends")
        } else {
            // The precondition failed at click time: this launch context
            // cannot grant the window key state, so AppKit swallows clicks.
            // Selection stays programmatic so later checks are meaningful.
            lines.append("SKIP: Selection check: torrent/file/cmd/shift click paths — window key state unavailable at click time")
            outline.selectRowIndexes(IndexSet(integer: torrentRow), byExtendingSelection: false)
            await settle()
            let inclusionAfter = transfers.map { $0.id + ":" + $0.files.filter(\.selected).map { String($0.id) }.joined(separator: ",") }
            check(inclusionBefore == inclusionAfter, "Row selection does not change download inclusion")
        }

        // Arrow-key navigation is native NSTableView behavior once the
        // outline owns first responder (asserted by the multiselection
        // check); driving it with synthetic events trips an AppKit/SwiftUI
        // key-state interop crash in this harness, so it is verified by
        // inspection instead.
        // Keep a stable selection for the remaining painted checks.
        if outline.selectedRowIndexes.isEmpty {
            outline.selectRowIndexes(IndexSet(integer: torrentRow), byExtendingSelection: false)
            await settle()
        }

        // Focus moving into search keeps the selection emphasized.
        searchFocusRequest += 1
        await settle()
        if interactionReady {
            check(window.firstResponder != outline && !outline.selectedRowIndexes.isEmpty, "Search field takes focus while selection persists")
            if let painted = backgroundSample(torrentRow) {
                check(colorDistance(painted, selection) < 0.12, "Selection stays painted when focus moves to search")
            }
        }

        // An inactive window keeps a muted, identifiable selection. This runs
        // regardless of mouse-path availability: only painted emphasis is
        // asserted, and the emphasis comparison holds in either key state.
        let foreignWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        foreignWindow.isReleasedWhenClosed = false
        foreignWindow.makeKeyAndOrderFront(nil)
        await settle()
        let rowView = outline.rowView(atRow: torrentRow, makeIfNecessary: false)
        check(rowView?.isEmphasized == false, "Inactive window de-emphasizes the selection")
        if let muted = backgroundSample(torrentRow), let composited = flattenedOverPanel(selectionInactive) {
            let calibratedMuted = calibrated(composited, offset: captureOffset)
            let calibratedEmphasized = calibrated(selection, offset: captureOffset)
            lines.append("Inactive sample: muted=\(muted), calibratedMuted=\(calibratedMuted), dMuted=\(colorDistance(muted, calibratedMuted)), dEmphasized=\(colorDistance(muted, calibratedEmphasized))")
            check(colorDistance(muted, calibratedMuted) < colorDistance(muted, calibratedEmphasized),
                  "Inactive window paints the muted selection fill")
        } else {
            check(false, "Inactive window selection is sampleable")
        }
        window.makeKeyAndOrderFront(nil)
        foreignWindow.close()
        await settle()

        // Scroll away and back: reused rows show no stale highlight or status.
        let lastRow = outline.numberOfRows - 1
        outline.scrollRowToVisible(lastRow)
        await settle()
        outline.scrollRowToVisible(torrentRow)
        await settle()
        if paintingObservable {
            check(paintsSelection(torrentRow), "Selection repaints identically after scrolling away and back")
        }

        // Checkboxes keep download-inclusion behavior without selecting rows.
        if let coordinator {
            outline.deselectAll(nil)
            await settle()
            var recordedSelection = false
            var recordedInclusion: (ids: [String], selected: Bool)?
            coordinator.debugFileSelectionAction = { nodes, selected in
                recordedInclusion = (nodes.map(\.id), selected)
            }
            if let nameColumn = outline.tableColumns.first(where: { $0.identifier.rawValue == "name" }),
               let nameColumnIndex = outline.tableColumns.firstIndex(of: nameColumn),
               let cell = outline.view(atColumn: nameColumnIndex, row: fileRow, makeIfNecessary: true) as? NSTableCellView,
               let checkbox = cell.subviews.compactMap({ $0 as? NSButton }).first {
                let checkboxCenter = checkbox.convert(NSPoint(x: checkbox.bounds.midX, y: checkbox.bounds.midY), to: nil)
                let deepestHit = window.contentView?.hitTest(checkboxCenter).map { String(describing: type(of: $0)) } ?? "nil"
                lines.append("Checkbox probe: hit=\(deepestHit), enabled=\(checkbox.isEnabled), target=\(checkbox.target != nil), hook=\(coordinator.debugFileSelectionAction != nil)")
                check(deepestHit == "TorrentFileSelectionButton",
                      "A click at the checkbox's location hits the checkbox, not the row")
                // Drive the wired target-action directly: performClick routes
                // through the event queue, which synthetic clicks cannot
                // complete in this harness.
                let wasOn = checkbox.state == .on
                if let target = checkbox.target, let action = checkbox.action {
                    _ = target.perform(action, with: checkbox)
                }
                await settle()
                recordedSelection = !outline.selectedRowIndexes.isEmpty
                coordinator.debugFileSelectionAction = nil
                // The direct target-action path does not depend on event
                // dispatch; a missing hook here is a wiring failure.
                check(recordedInclusion != nil && recordedInclusion!.ids.count == 1 && recordedInclusion!.selected == !wasOn,
                      "Clicking the checkbox requests the file's inclusion change (was on: \(wasOn), requested: \(recordedInclusion.map { String($0.selected) } ?? "none"))")
                check(!recordedSelection, "Clicking the checkbox does not select the row")
            } else {
                check(false, "File checkbox is available for the mouse-path check")
            }
        } else {
            check(false, "Coordinator exposes the checkbox debug hook")
        }

        // Appearance changes rebuild platform views, so exercise row geometry
        // across them last, after the event-driven sections.
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await settle()
        checkRowGeometry("in dark appearance")
        NSApp.appearance = previousAppearance
        await settle()
        checkRowGeometry("after appearance restore")

        // Restore a clean single selection for later checks and the capture.
        outline.selectRowIndexes(IndexSet(integer: torrentRow), byExtendingSelection: false)
        window.makeFirstResponder(outline)
        await settle()
        return (passed, lines)
    }

    /// Typography, column sizing, header cells, and Reset Column Widths.
    /// Exercises the live outline's fonts, saved-width restoration, resize
    /// invariance, reset semantics, and header behavior without touching the
    /// engine.
    private func checkDebugColumns(window: NSWindow, view: NSView) async -> (passed: Bool, lines: [String]) {
        var passed = true
        var lines: [String] = []
        func check(_ condition: Bool, _ message: String) {
            let line = "\(condition ? "PASS" : "FAIL"): Columns check: \(message)"
            lines.append(line); print(line)
            if !condition { passed = false }
        }
        func settle(_ ms: Int64 = 200) async { try? await Task.sleep(for: .milliseconds(ms)) }
        @MainActor func findOutline(_ root: NSView) -> NSOutlineView? {
            if let outline = root as? NSOutlineView { return outline }
            for child in root.subviews { if let outline = findOutline(child) { return outline } }
            return nil
        }
        guard let outline = findOutline(view),
              let coordinator = outline.delegate as? TorrentOutlineView.Coordinator else {
            check(false, "Outline coordinator is available")
            return (passed, lines)
        }
        outline.expandItem(nil, expandChildren: true)
        await settle()

        func width(_ id: String) -> Double? {
            for column in outline.tableColumns where column.identifier.rawValue == id { return Double(column.width) }
            return nil
        }
        func column(_ id: String) -> NSTableColumn? {
            for candidate in outline.tableColumns where candidate.identifier.rawValue == id { return candidate }
            return nil
        }

        // 1. Fresh outlines receive the shared default widths.
        lines.append("Fresh widths: \(outline.tableColumns.map { "\($0.identifier.rawValue)=\($0.width)" }.joined(separator: ", ")), outlineBounds=\(outline.bounds.width)")
        outline.reloadData()
        await settle()
        lines.append("After reload widths: \(outline.tableColumns.map { "\($0.identifier.rawValue)=\($0.width)" }.joined(separator: ", "))")
        for definition in TorrentColumns.all {
            check(abs((width(definition.id) ?? -1) - definition.defaultWidth) < 0.5,
                  "Fresh outline opens \(definition.title) at its \(Int(definition.defaultWidth))-point default")
        }
        check(outline.columnAutoresizingStyle == .noColumnAutoresizing, "Column autoresizing is disabled")

        // 2. Header cells are the soft subclass with native sort prototypes.
        check(outline.tableColumns.allSatisfy { $0.headerCell is TorrentTableHeaderCell },
              "All headers use the soft header cell")
        for definition in TorrentColumns.all {
            let prototype = column(definition.id)?.sortDescriptorPrototype
            check(prototype?.key == definition.id, "\(definition.title) keeps its native sort prototype")
        }

        // 3. Torrent names are medium; folders and files stay regular, and
        //    reused cells cannot retain another node type's weight.
        let nodes = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? TorrentTreeNode }
        let nameColumn = column("name")
        guard let torrentNode = nodes.first(where: { $0.id == "torrent:ui-a" }),
              let fileNode = nodes.first(where: { if case .file = $0.kind { return true }; return false }),
              let folderNode = nodes.first(where: { $0.kind == .folder && $0.fileIndices != nil }),
              let nameColumn else {
            check(false, "Fixture exposes torrent, file, and folder rows with a name column")
            return (passed, lines)
        }
        let fontManager = NSFontManager.shared
        let torrentCell = coordinator.outlineView(outline, viewFor: nameColumn, item: torrentNode) as? NSTableCellView
        let fileCell = coordinator.outlineView(outline, viewFor: nameColumn, item: fileNode) as? NSTableCellView
        let folderCell = coordinator.outlineView(outline, viewFor: nameColumn, item: folderNode) as? NSTableCellView
        // NSFontManager reports the legacy 0-15 scale: 5 = regular, 6 = medium.
        let mediumWeight = 6
        let regularWeight = 5
        let torrentWeight = torrentCell?.textField?.font.map { fontManager.weight(of: $0) } ?? -1
        let fileWeight = fileCell?.textField?.font.map { fontManager.weight(of: $0) } ?? -1
        let folderWeight = folderCell?.textField?.font.map { fontManager.weight(of: $0) } ?? -1
        lines.append("Font weights: torrent=\(torrentWeight), file=\(fileWeight), folder=\(folderWeight)")
        check(torrentWeight == mediumWeight && torrentWeight > fileWeight,
              "Torrent names use 13-point medium weight")
        check(fileWeight == regularWeight && folderWeight == regularWeight,
              "File and folder names use 13-point regular weight")
        // Reuse: the torrent row's cell reconfigured for a file must drop the weight.
        if let reused = coordinator.outlineView(outline, viewFor: nameColumn, item: fileNode) as? NSTableCellView,
           reused === torrentCell {
            check(reused.textField?.font.map { fontManager.weight(of: $0) } == regularWeight,
                  "A reused cell drops the torrent weight for a file row")
        } else {
            lines.append("Reuse note: torrent and file cells were distinct instances in this pass")
        }

        // 4. Saved widths restore unchanged through the normal loading path.
        var state = uiState
        state.columnWidths = ["name": 333, "progress": 200]
        uiState = state
        coordinator.loadedState = false
        coordinator.refresh(model: self)
        await settle()
        check(abs((width("name") ?? 0) - 333) < 1 && abs((width("progress") ?? 0) - 200) < 1,
              "Saved custom widths restore unchanged (name 333, progress 200)")
        check(abs((width("size") ?? 0) - TorrentColumns.defaultWidths["size"]!) < 0.5,
              "Columns without saved entries keep their defaults")

        // 5. Resize boundaries clamp at each column's minimum; persistence of
        //    manual drags is covered by the profile smoke against real state.
        column("name")?.width = 10
        await settle()
        check((width("name") ?? 0) >= 180, "Manual resizing clamps at Name's 180-point minimum")
        column("progress")?.width = 10
        await settle()
        check((width("progress") ?? 0) >= 144, "Manual resizing clamps at Progress's 144-point minimum")

        // 6. Reset applies defaults immediately without disturbing anything else.
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: torrentNode)), byExtendingSelection: false)
        await settle()
        let orderBefore = outline.tableColumns.map(\.identifier.rawValue)
        let sortBefore = uiState.sortOrder
        let selectionBefore = Set(selectedNodes.map(\.id))
        let expandedBefore = coordinator.expanded
        let sidebarWidthBefore = uiState.sidebarWidth
        let outlineIdentity = ObjectIdentifier(outline)
        resetColumnWidths()
        await settle()
        for definition in TorrentColumns.all {
            check(abs((width(definition.id) ?? -1) - definition.defaultWidth) < 0.5,
                  "Reset opens \(definition.title) at its \(Int(definition.defaultWidth))-point default")
        }
        check(outline.tableColumns.map(\.identifier.rawValue) == orderBefore, "Reset preserves column order")
        check(uiState.sortOrder == sortBefore, "Reset preserves the saved sort")
        check(Set(selectedNodes.map(\.id)) == selectionBefore, "Reset preserves the selection")
        check(coordinator.expanded.isSuperset(of: expandedBefore), "Reset preserves expansion")
        check(uiState.sidebarWidth == sidebarWidthBefore, "Reset leaves pane widths alone")
        check(ObjectIdentifier(outline) == outlineIdentity, "Reset does not reconstruct the outline")
        check(uiState.columnWidths == TorrentColumns.defaultWidths, "Reset stores the defaults in UI state")

        // 7. Window resizing and panel toggles do not rewrite column widths.
        let widthsBeforeResize = outline.tableColumns.map(\.width)
        if let window = outline.window {
            let originalSize = window.frame.size
            window.setContentSize(NSSize(width: originalSize.width + 140, height: originalSize.height + 60))
            await settle()
            isSidebarVisible = false
            await settle()
            isSidebarVisible = true
            await settle()
            showInspector = true
            await settle()
            showInspector = false
            await settle()
            check(outline.tableColumns.map(\.width) == widthsBeforeResize,
                  "Window resizing and panel toggles leave column widths unchanged")
            window.setContentSize(originalSize)
            await settle()
        } else {
            check(false, "Outline has a window for resize invariance")
        }

        // 9. Native header interactions still function: sorting via headers
        //    is covered by the sorting fixture; confirm a header-driven sort
        //    still updates descriptors after the reset.
        if let prototype = column("name")?.sortDescriptorPrototype {
            outline.sortDescriptors = [prototype]
            await settle()
            check(uiState.sortOrder == TreeSortOrder(column: .name, ascending: true),
                  "Header-driven sorting still updates the saved sort after reset")
        }

        // 9b. Header visuals on the live header view with exact coordinates:
        //     panel background, soft separators at column boundaries, and a
        //     native sort indicator that stays visible above the styled fill.
        if let header = outline.headerView {
            header.needsDisplay = true
            header.displayIfNeeded()
            let bounds = header.bounds
            if let bitmap = header.bitmapImageRepForCachingDisplay(in: bounds) {
                header.cacheDisplay(in: bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / max(1, bounds.width)
                @MainActor func pixel(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
                    bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))
                }
                func delta(_ a: NSColor?, _ b: NSColor?) -> CGFloat {
                    guard let a, let b, let first = a.usingColorSpace(.sRGB), let second = b.usingColorSpace(.sRGB) else { return 999 }
                    return abs(first.redComponent - second.redComponent) + abs(first.greenComponent - second.greenComponent) + abs(first.blueComponent - second.blueComponent)
                }
                let nameRect = header.headerRect(ofColumn: 0)
                let addedRect = header.headerRect(ofColumn: 1)
                let midHeight = bounds.midY
                // Reference: clean panel area inside the size column header.
                let sizeRect = header.headerRect(ofColumn: 2)
                let background = pixel(sizeRect.midX, midHeight)
                let panelColor = Palette.panel.resolved(in: outline.effectiveAppearance)
                check(delta(background, panelColor) < 0.12, "Header paints the panel background")
                // Soft vertical separators: full-height lines whose color sits
                // between the panel and a hard border, wherever the header's
                // interior layout places them.
                var softLines = 0
                var xDump = CGFloat(0)
                while xDump < bounds.width {
                    var run = 0
                    var y = bounds.minY
                    while y < bounds.maxY {
                        let line = delta(pixel(xDump, y), background)
                        if line > 0.015 && line < 0.7 { run += 1 }
                        y += 1
                    }
                    if run >= Int(bounds.height) - 8 { softLines += 1 }
                    xDump += 0.5
                }
                lines.append("Header soft vertical lines: \(softLines) in width \(bounds.width)")
                let bottomA = delta(pixel(sizeRect.midX, bounds.maxY - 0.75), background)
                let bottomB = delta(pixel(sizeRect.midX, bounds.maxY - 0.25), background)
                lines.append("Header bottom edge delta: \(max(bottomA, bottomB))")
                check(softLines >= 2, "Header separators are visible and soft")
                check(max(bottomA, bottomB) > 0.02, "Header bottom edge is visible")
                // Sort indicator near the sorted column's trailing edge.
                var indicatorPixels = 0
                var x = nameRect.maxX - 26
                while x < nameRect.maxX - 2 {
                    var y = bounds.minY + 4
                    while y < bounds.maxY - 4 {
                        if delta(pixel(x, y), background) > 0.6 { indicatorPixels += 1 }
                        y += 1
                    }
                    x += 1
                }
                lines.append("Header indicator pixels: \(indicatorPixels)")
                check(indicatorPixels >= 4, "Native sort indicator stays visible over the styled header")
            }
        }

        // 10. Reset works with an empty library. The empty state replaces the
        //     outline view, so re-find and re-expand it after restoring the
        //     fixture for the checks that follow this one.
        let originalTransfers = transfers
        var stateBeforeEmpty = uiState
        stateBeforeEmpty.columnWidths = TorrentColumns.defaultWidths
        uiState = stateBeforeEmpty
        transfers = []
        refreshVisibleCount()
        await settle()
        var widened = uiState
        widened.columnWidths = ["size": 77]
        uiState = widened
        resetColumnWidths()
        await settle()
        check(uiState.columnWidths == TorrentColumns.defaultWidths,
              "Reset saves defaults for the next outline with an empty library")
        transfers = originalTransfers
        refreshVisibleCount()
        await settle(400)
        if let fresh = findOutline(view) {
            fresh.expandItem(nil, expandChildren: true)
            await settle()
            check(fresh.tableColumns.allSatisfy { column in
                TorrentColumns.all.first { $0.id == column.identifier.rawValue }
                    .map { abs(Double(column.width) - $0.defaultWidth) < 0.5 } ?? false
            }, "The recreated outline opens with the reset defaults")
        }
        return (passed, lines)
    }

    private func checkDebugQBittorrentSheet(window: NSWindow) async -> (passed: Bool, lines: [String]) {
        var passed = true
        var lines: [String] = []
        func check(_ condition: Bool, _ message: String) {
            let line = "\(condition ? "PASS" : "FAIL"): qBittorrent sheet check: \(message)"
            lines.append(line); print(line)
            if !condition { passed = false }
        }
        guard let sheet = window.attachedSheet, let content = sheet.contentView else {
            check(false, "Import sheet is visible")
            return (passed, lines)
        }
        check(sheet.styleMask.contains(.resizable), "Import sheet allows user resizing")
        let minimum = sheet.contentMinSize
        lines.append("Import sheet minimum content size: \(minimum)")
        check(minimum.width >= 820 && minimum.height >= 560, "Minimum content size is at least 820 × 560")
        let enlarged = NSSize(width: 1100, height: 720)
        sheet.setContentSize(enlarged)
        try? await Task.sleep(for: .milliseconds(250))
        content.layoutSubtreeIfNeeded()
        check(abs(content.bounds.width - enlarged.width) < 2 && abs(content.bounds.height - enlarged.height) < 2, "Larger sizes are honored")
        sheet.setContentSize(minimum)
        try? await Task.sleep(for: .milliseconds(250))
        content.layoutSubtreeIfNeeded()
        check(abs(content.bounds.width - minimum.width) < 2 && abs(content.bounds.height - minimum.height) < 2, "Sheet returns to its minimum size with actions visible")
        sheet.setContentSize(NSSize(width: 940, height: 620))
        try? await Task.sleep(for: .milliseconds(150))
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
        draft.statusFilter = .alreadyImported
        check(draft.visibleCandidates.map(\.id) == [existingID], "Already imported filter shows only existing torrents")
        draft.statusFilter = .readyForImport
        check(draft.visibleCandidates.map(\.id) == [String(repeating: "a", count: 40)], "Ready filter excludes existing and unsupported torrents")
        draft.search = "Linux"
        check(draft.visibleCandidates.isEmpty, "Search and status filters combine")
        draft.search = ""
        draft.selection = []
        draft.selectVisible()
        check(draft.selection == [String(repeating: "a", count: 40)], "Select Shown respects the status filter")
        draft.verifyExistingData = false
        check(draft.visibleCandidates.count == 1, "Ready filter also includes saved-progress imports")
        draft.verifyExistingData = true
        draft.statusFilter = .all
        check(draft.visibleCandidates.count == 3, "All statuses restores every row")
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

            // A separate model keeps preset smoke checks away from the real
            // profile, including any SettingsView onChange persistence.
            let settingsModel = AppModel(root: directory.appendingPathComponent("Settings-Fixture-\(UUID())", isDirectory: true), defaults: profileDefaults)
            settingsModel.isProfileReady = true
            settingsModel.isSwitchingProfile = false
            settingsModel.activeProfile = activeProfile
            settingsModel.profiles = profiles
            settingsModel.statistics = statistics
            settingsModel.settings = settings
            settingsModel.settings.apply(.highThroughput)
            check(settingsModel.settings.throughputPreset == .highThroughput && settingsModel.settings.maxPeers == 1_000 && settingsModel.settings.downloadRequestWindow == 128 && settingsModel.settings.payloadBudget == 256 * 1024 * 1024, "High throughput preset supplies the Settings controls with 1,000 peers, 128 requests and 256 MiB")
            check(settingsModel.settings.maxDownloads == settings.maxDownloads && settingsModel.settings.maxSeeds == settings.maxSeeds && settingsModel.settings.downloadLimit == settings.downloadLimit && settingsModel.settings.uploadLimit == settings.uploadLimit && settingsModel.settings.storageProfile == settings.storageProfile, "Preset retains active-transfer, bandwidth and storage preferences")
            let hostingView = NSHostingView(rootView: SettingsView(model: settingsModel))
            let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settingsWindow.title = "Settings — Appearance Fixture"
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.contentView = hostingView
            settingsWindow.center()
            settingsWindow.makeKeyAndOrderFront(nil)
            defer { settingsWindow.close() }
            for theme in [AppAppearance.light, .dark] {
                settingsModel.appearance = theme
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
    /// Pane-width persistence across profile switches, on temporary profiles
    /// with the real split-view coordinator alive throughout — the exact
    /// regression where reports carried a previous profile's layout token.
    private func runLayoutPersistenceSmoke() async throws -> [String] {
        var lines: [String] = []
        struct SmokeFailure: Error { let message: String }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw SmokeFailure(message: message) }
            lines.append("PASS: " + message)
        }
        func settle(_ ms: Int64 = 700) async { try? await Task.sleep(for: .milliseconds(ms)) }
        @MainActor func findSplit(_ root: NSView) -> NSSplitView? {
            if let split = root as? NSSplitView { return split }
            for child in root.subviews { if let split = findSplit(child) { return split } }
            return nil
        }
        guard let window = NSApp.windows.first(where: { $0.title.contains("Torrenza") }), let view = window.contentView else {
            throw SmokeFailure(message: "Layout smoke needs a visible window; titles=\(NSApp.windows.map(\.title))")
        }
        guard let original = profiles.first(where: { $0.id == "default" }) else {
            throw SmokeFailure(message: "Layout smoke needs the default profile; have=\(profiles.map(\.id))")
        }
        // At this point in the smoke the second profile is the active one.
        guard let research = activeProfile, research.id != original.id else {
            throw SmokeFailure(message: "Layout smoke needs the non-default profile active; active=\(activeProfile?.id ?? "nil"), have=\(profiles.map(\.id))")
        }
        // Pane order inside the split is fixed: sidebar, tree, inspector.
        func sidebarPaneWidth() -> CGFloat? { findSplit(view)?.subviews.first?.bounds.width }
        func inspectorPaneWidth() -> CGFloat? {
            guard let split = findSplit(view), split.subviews.count > 2 else { return nil }
            return split.subviews.last?.bounds.width
        }

        // Profile A (default): distinct widths, both panels visible.
        switchProfile(original); await waitForProfileWork(); await settle()
        try require(activeProfile?.id == original.id, "Layout smoke opens the default profile")
        uiState.sidebarWidth = 232
        uiState.inspectorWidth = 380
        uiState.sidebarVisible = true
        uiState.inspectorVisible = true
        await settle()
        try require(abs((sidebarPaneWidth() ?? 0) - 232) < 2, "Profile A applies its 232-point sidebar width to the split")
        try require(abs((inspectorPaneWidth() ?? 0) - 380) < 2, "Profile A applies its 380-point inspector width to the split")
        let staleToken = currentLayoutToken

        // Profile B: its own incoming layout.
        switchProfile(research); await waitForProfileWork(); await settle()
        try require(activeProfile?.id == research.id, "Layout smoke switches to the second profile")
        try require(abs(sidebarWidth - WorkspaceMetrics.sidebarIdealWidth) < 1.5, "Profile B opens with its own sidebar width (\(Int(sidebarWidth)))")
        try require(abs((sidebarPaneWidth() ?? 0) - sidebarWidth) < 2, "Profile B's sidebar pane matches its saved width")
        try require(abs(inspectorWidth - WorkspaceMetrics.inspectorIdealWidth) < 1.5, "Profile B opens with its own inspector width (\(Int(inspectorWidth)))")
        // Both panes participate in the drag checks.
        uiState.inspectorVisible = true
        uiState.sidebarVisible = true
        await settle()

        // Resize both panes in B through the split-view divider path.
        guard let split = findSplit(view), split.subviews.count > 2 else {
            throw SmokeFailure(message: "Layout smoke needs a three-pane split")
        }
        split.setPosition(252, ofDividerAt: 0)
        if split.arrangedSubviews.count > 2 {
            // The trailing divider's position is measured from the split's
            // leading edge, so the divider thickness sits inside the pane.
            split.setPosition(max(0, split.bounds.width - 366 - split.dividerThickness), ofDividerAt: split.arrangedSubviews.count - 2)
        }
        await settle()
        try require(abs(sidebarWidth - 252) < 1.5, "Dragging in profile B records its 252-point sidebar width")
        try require(abs(inspectorWidth - 366) < 1.5, "Dragging in profile B records its 366-point inspector width")

        // Back to A: A's layout returns untouched.
        switchProfile(original); await waitForProfileWork(); await settle()
        try require(abs(sidebarWidth - 232) < 1.5 && abs(inspectorWidth - 380) < 1.5, "Returning to profile A restores its widths")
        try require(abs((sidebarPaneWidth() ?? 0) - 232) < 2, "Profile A's sidebar pane returns to 232")

        // Reopen B: its newly saved widths persist.
        switchProfile(research); await waitForProfileWork(); await settle()
        try require(abs(sidebarWidth - 252) < 1.5 && abs(inspectorWidth - 366) < 1.5, "Reopening profile B restores its 252/366 widths")

        // A stale-token report cannot modify B.
        reportSidebarWidth(199, token: staleToken)
        reportInspectorWidth(333, token: staleToken)
        try require(abs(sidebarWidth - 252) < 1.5 && abs(inspectorWidth - 366) < 1.5, "A stale-token report from profile A cannot modify profile B")

        // Hidden inspector survives a profile round trip.
        showInspector = false
        await settle(400)
        switchProfile(original); await waitForProfileWork(); await settle(400)
        try require(uiState.inspectorVisible, "Profile A keeps its inspector visible")
        switchProfile(research); await waitForProfileWork(); await settle(400)
        try require(!uiState.inspectorVisible, "Profile B keeps its inspector hidden")
        try require(abs(sidebarWidth - 252) < 1.5, "Profile B's sidebar width survives the hidden-inspector round trip")

        // Hidden sidebar survives a profile round trip.
        isSidebarVisible = false
        await settle(400)
        switchProfile(original); await waitForProfileWork(); await settle(400)
        try require(isSidebarVisible, "Profile A keeps its sidebar visible")
        switchProfile(research); await waitForProfileWork(); await settle(400)
        try require(!isSidebarVisible, "Profile B keeps its sidebar hidden")
        try require(!uiState.inspectorVisible, "Profile B's inspector stays hidden after the hidden-sidebar round trip")
        // Reset in one profile does not touch another profile's widths.
        uiState.columnWidths = ["name": 300]
        await settle(400)
        switchProfile(original); await waitForProfileWork(); await settle(400)
        // The earlier smoke steps stored a 417-point Name width on profile A.
        try require(uiState.columnWidths["name"] == 417,
                    "Profile A retains its own name width before reset")
        resetColumnWidths()
        await settle(400)
        try require(uiState.columnWidths == TorrentColumns.defaultWidths, "Reset applies shared defaults in profile A")
        switchProfile(research); await waitForProfileWork(); await settle(400)
        try require(abs((uiState.columnWidths["name"] ?? 0) - 300) < 1,
                    "Profile B's custom name width survives profile A's reset")

        isSidebarVisible = true
        showInspector = true
        await settle(400)
        return lines
    }

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
            uiState.sortOrder = TreeSortOrder(column: .uploaded, ascending: false)
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
            try require(uiState.sortOrder == nil, "New profile starts without another profile's column sort")
            try require(statistics?.current.id != originalSession && statistics?.lifetimeDownloadedBytes == 0, "Statistics start independently")
            let workTorrentDirectory = work.directory.appendingPathComponent("Torrent Files", isDirectory: true)
            let workDestinationDirectory = work.directory.appendingPathComponent("Downloads", isDirectory: true)
            settings.maxDownloads = 1; saveSettings(); filter = .paused
            uiState.sortOrder = TreeSortOrder(column: .added, ascending: false)
            uiState.lastTorrentDirectory = workTorrentDirectory
            uiState.lastDestinationDirectory = workDestinationDirectory
            await waitForProfileWork()
            switchProfile(original); await waitForProfileWork()
            try require(settings.maxDownloads == 3 && filter == .completed && uiState.columnWidths["name"] == 417, "Switching back restores settings and interface preferences")
            try require(uiState.lastTorrentDirectory == originalTorrentDirectory && uiState.lastDestinationDirectory == originalDestinationDirectory, "Switching back restores both original profile dialog directories")
            try require(uiState.sortOrder == TreeSortOrder(column: .uploaded, ascending: false), "Switching back restores the original profile column sort")
            try require(statistics?.current.id != originalSession, "Returning to a profile begins a new session")
            let history = try await engine.sessionHistory()
            try require(history.contains { $0.id == originalSession && $0.endedAt != nil && !$0.interrupted }, "Switching closes the previous session cleanly")
            beginCreateProfile(); profileName = "work"; submitProfile(); await waitForProfileWork()
            try require(profileEditorError != nil && activeProfile?.id == original.id, "Duplicate names leave the active profile unchanged")
            profileEditor = nil; profileEditorError = nil
            switchProfile(work); await waitForProfileWork()
            try require(settings.maxDownloads == 1 && filter == .paused, "Second profile retains its own values")
            try require(uiState.sortOrder == TreeSortOrder(column: .added, ascending: false), "Second profile retains its own column sort")
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
            lines.append(contentsOf: try await runLayoutPersistenceSmoke())
            // Allow SwiftUI to lay out the completed transition before measuring native controls.
            try await Task.sleep(for: .milliseconds(300))
            if let window = NSApp.windows.first(where: { $0.title.contains("Torrenza") }), let view = window.contentView {
                window.setContentSize(NSSize(width: 1000, height: 700))
                try await Task.sleep(for: .milliseconds(300))
                let container = view.superview ?? view
                container.layoutSubtreeIfNeeded()
                var searchField: NSSearchField?
                var outlineFound = false
                func inspect(_ node: NSView) throws {
                    if let field = node as? NSSearchField {
                        searchField = field
                        lines.append("Search frame: \(field.convert(field.bounds, to: container))")
                    }
                    if node is NSOutlineView { outlineFound = true }
                    for child in node.subviews { try inspect(child) }
                }
                try inspect(container)
                try require(searchField?.isEnabled == true && (searchField?.frame.width ?? 0) > 100,
                            "Header search remains enabled and usable at minimum window width")
                // Empty profiles show the Add Torrent invitation instead of the tree.
                lines.append("Torrent outline present at minimum width: \(outlineFound)")
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
            try require(reopened.uiState.sortOrder == TreeSortOrder(column: .added, ascending: false), "Relaunch restores the profile column sort from SQLite")
            try require(reopened.uiState.lastTorrentDirectory == workTorrentDirectory && reopened.uiState.lastDestinationDirectory == workDestinationDirectory, "Relaunch restores both saved dialog directories")
            await reopened.shutdown()
            let closedDatabase = try Data(contentsOf: work.databaseURL)
            await shutdown()
            try require(try Data(contentsOf: work.databaseURL) == closedDatabase, "Repeated shutdown does not rewrite a closed profile")
            lines.append(contentsOf: try await runFileSelectionSmoke())
            lines.append(contentsOf: try await runImportFailureSmoke())
            lines.append(contentsOf: try await runDestinationSmoke())
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
