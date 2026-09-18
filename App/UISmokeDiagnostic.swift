#if DEBUG
import AppKit
import Foundation
import TorrentCore
import TorrentEngine
import TorrentStorage

/// Explicit developer launch option. It does not start the engine or persist fixtures.
@MainActor extension AppModel {
    func installDebugFixture() {
        didLoadUIState = true
        let arguments = ProcessInfo.processInfo.arguments
        let longProfile = arguments.contains("--ui-long-profile")
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
        let files = [FileSnapshot(file: TorrentFile(index: 0, path: ["A", "Documents", "Guide.pdf"], length: 4_000_000, offset: 0), selected: true, verifiedBytes: 2_000_000), FileSnapshot(file: TorrentFile(index: 1, path: ["A", "Archive.zip"], length: 46_000_000, offset: 4_000_000), selected: true, verifiedBytes: 19_000_000)]
        transfers = [
            TransferSnapshot(id: "ui-a", name: "A", destination: URL(fileURLWithPath: "/Volumes/Storage/torrents/other"), isMultiFile: true, state: .downloading, files: files, completedBytes: 21_000_000, selectedBytes: 50_000_000, downloadedBytes: 21_000_000, uploadedBytes: 2_000_000, downloadRate: 4_200_000, uploadRate: 128_000, swarm: swarm, trackers: ["https://tracker.example.test/announce"]),
            TransferSnapshot(id: "ui-b", name: "B", destination: URL(fileURLWithPath: "/Volumes/Storage/torrents/video"), isMultiFile: true, state: .seeding, files: [.init(file: .init(index: 0, path: ["B", "Movie.mp4"], length: 1_200_000_000, offset: 0), selected: true, verifiedBytes: 1_200_000_000)], completedBytes: 1_200_000_000, selectedBytes: 1_200_000_000, downloadedBytes: 1_200_000_000, uploadedBytes: 720_000_000, uploadRate: 2_100_000, swarm: swarm),
            TransferSnapshot(id: "ui-offline", name: "Linux.iso", destination: URL(fileURLWithPath: "/Volumes/Backup"), state: .unavailable, selectedBytes: 4_000_000_000, error: "Connect Backup to resume this download.")
        ]
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
                    if let node = outline.item(atRow: row) as? TorrentTreeNode, node.id == "torrent:ui-a" { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); break }
                }
            }
            try? await Task.sleep(for: .milliseconds(600))
            let captureView = view.superview ?? view
            captureView.layoutSubtreeIfNeeded(); captureView.displayIfNeeded()
            guard let bitmap = captureView.bitmapImageRepForCachingDisplay(in: captureView.bounds) else { return }
            captureView.cacheDisplay(in: captureView.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Torrenza-UI", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let basename = "ui-smoke-\(dark ? "dark" : "light")\(narrow ? "-narrow" : wide ? "-wide" : "")\(longProfile ? "-long-profile" : "")"
            let output = directory.appendingPathComponent(basename + ".png")
            try? png.write(to: output, options: .atomic)
            var geometry = ["Window content size: \(view.bounds.size)", "Profile name: \(fixtureName)", "Toolbar item count: \(window.toolbar?.items.count ?? 0)"]
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
            try? geometry.joined(separator: "\n").write(to: directory.appendingPathComponent(basename + ".txt"), atomically: true, encoding: .utf8)
            captured = searchChecksPassed
            print("UI snapshot: \(output.path)")
        }
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
            settings.maxDownloads = 3; saveSettings()
            uiState.filter = TreeFilter.completed.rawValue
            uiState.columnWidths["name"] = 417
            await waitForProfileWork()
            beginCreateProfile(); profileName = "Work"; submitProfile()
            await waitForProfileWork()
            try require(error == nil && activeProfile?.name == "Work", "Creating a profile activates it")
            let work = activeProfile!
            try require(work.databaseURL != original.databaseURL && transfers.isEmpty, "New profile uses an independent empty database")
            try require(settings.maxDownloads == 2 && filter == .all && uiState.columnWidths.isEmpty, "Settings and interface preferences do not leak")
            try require(statistics?.current.id != originalSession && statistics?.lifetimeDownloadedBytes == 0, "Statistics start independently")
            settings.maxDownloads = 1; saveSettings(); filter = .paused
            await waitForProfileWork()
            switchProfile(original); await waitForProfileWork()
            try require(settings.maxDownloads == 3 && filter == .completed && uiState.columnWidths["name"] == 417, "Switching back restores settings and interface preferences")
            try require(statistics?.current.id != originalSession, "Returning to a profile begins a new session")
            let history = try await engine.sessionHistory()
            try require(history.contains { $0.id == originalSession && $0.endedAt != nil && !$0.interrupted }, "Switching closes the previous session cleanly")
            beginCreateProfile(); profileName = "work"; submitProfile(); await waitForProfileWork()
            try require(profileEditorError != nil && activeProfile?.id == original.id, "Duplicate names leave the active profile unchanged")
            profileEditor = nil; profileEditorError = nil
            switchProfile(work); await waitForProfileWork()
            try require(settings.maxDownloads == 1 && filter == .paused, "Second profile retains its own values")
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
