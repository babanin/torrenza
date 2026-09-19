import AppKit
import Observation
import SwiftUI
import TorrentCore
import TorrentEngine

@MainActor @Observable final class QBittorrentImportDraft: Identifiable {
    let id = UUID()
    var candidates: [QBittorrentImportCandidate] = []
    var selection: Set<String> = []
    var verifyExistingData = true
    var sourceURL: URL?
    var isScanning = false
    var isImporting = false
    var stopRequested = false
    var error: String?
    var outcomes: [String: String] = [:]
    var search = ""
    var progress = ""
    var importedCount = 0
    private(set) var existingIDs: Set<String>
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var sourceIsScoped = false
    @ObservationIgnored private var destinationGrants: [String: URL] = [:]
    @ObservationIgnored private var scopedDestinations: [URL] = []
    @ObservationIgnored private var activePanel: NSOpenPanel?
    @ObservationIgnored private var isClosed = false

    init(existingIDs: Set<String>) { self.existingIDs = existingIDs }

    var visibleCandidates: [QBittorrentImportCandidate] {
        guard !search.isEmpty else { return candidates }
        return candidates.filter { $0.name.localizedStandardContains(search) || ($0.destination?.path.localizedStandardContains(search) ?? false) }
    }
    func canSelect(_ candidate: QBittorrentImportCandidate) -> Bool {
        candidate.issue == nil && !existingIDs.contains(candidate.id)
    }
    func status(_ candidate: QBittorrentImportCandidate) -> String {
        if let outcome = outcomes[candidate.id] { return outcome }
        if existingIDs.contains(candidate.id) { return "Already in this profile" }
        return candidate.issue.map { "Unsupported: \($0)" } ?? (verifyExistingData ? "Ready to verify" : "Ready to import")
    }
    func selectVisible() { selection.formUnion(visibleCandidates.filter(canSelect).map(\.id)) }

    func chooseBackupFolder() {
        guard !isClosed, !isScanning, !isImporting, activePanel == nil else { return }
        let panel = NSOpenPanel()
        activePanel = panel
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Read Torrents"
        panel.message = "Choose qBittorrent’s BT_backup folder. Its saved torrents and settings will only be read."
        // NSHomeDirectory() is the app container in a sandboxed process.
        let home = NSHomeDirectoryForUser(NSUserName()) ?? FileManager.default.homeDirectoryForCurrentUser.path
        panel.directoryURL = sourceURL ?? URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/qBittorrent/BT_backup", isDirectory: true)
        panel.begin { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.activePanel = nil
                guard !self.isClosed, result == .OK, let url = panel.url else { return }
                self.scan(url)
            }
        }
    }

    private func scan(_ url: URL) {
        releaseAccess()
        sourceURL = url
        sourceIsScoped = url.startAccessingSecurityScopedResource()
        selection = []; candidates = []; outcomes = [:]; error = nil; importedCount = 0
        isScanning = true
        scanTask = Task {
            defer { isScanning = false; scanTask = nil }
            let worker = Task.detached(priority: .userInitiated) { try QBittorrentImport.scan(directory: url) }
            do {
                candidates = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                if candidates.isEmpty { error = "No saved torrents were found. Choose qBittorrent’s BT_backup folder." }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    func cancelScanning() async {
        scanTask?.cancel()
        await scanTask?.value
    }

    func requestClose() {
        isClosed = true
        stopRequested = true
        scanTask?.cancel()
        activePanel?.cancel(nil)
    }

    private func grantAccess(to destination: URL) async throws -> URL {
        guard !isClosed else { throw CancellationError() }
        let path = destination.standardizedFileURL.path
        if let granted = destinationGrants[path] { return granted }
        let panel = NSOpenPanel()
        activePanel = panel
        defer { activePanel = nil }
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.directoryURL = destination
        panel.prompt = "Use Existing Folder"
        panel.message = "Allow Torrenza to use the existing downloads in \(path). Choose this exact folder; files will stay in place."
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard !isClosed, response == .OK, let url = panel.url else { throw CancellationError() }
        guard url.standardizedFileURL.path == path else {
            throw TorrentError.storage("Choose the saved destination \(path). Moving downloads during import is not supported.")
        }
        if url.startAccessingSecurityScopedResource() { scopedDestinations.append(url) }
        destinationGrants[path] = url
        return url
    }

    func importSelected(engine: TorrentEngine, defaultSeedRatio: Double) async {
        defer { isImporting = false; progress = "" }
        guard !isClosed else { return }
        stopRequested = false; error = nil
        let verifyData = verifyExistingData
        let chosen = candidates.filter { selection.contains($0.id) && canSelect($0) }
        guard !chosen.isEmpty else { return }
        // Obtain all folder grants before adding any of the selected transfers.
        do {
            var paths = Set<String>()
            for candidate in chosen {
                guard !stopRequested, !Task.isCancelled else { return }
                guard let destination = candidate.destination else { continue }
                if paths.insert(destination.path).inserted {
                    progress = "Choose access to \(destination.lastPathComponent)…"
                    _ = try await grantAccess(to: destination)
                }
            }
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription; return }

        var failed = 0
        for (index, candidate) in chosen.enumerated() {
            guard !stopRequested, !Task.isCancelled else { break }
            progress = "\(index + 1) of \(chosen.count) · \(candidate.name)"
            outcomes[candidate.id] = "Checking existing files…"
            do {
                let payload = try await Task.detached(priority: .utility) {
                    let payload = try QBittorrentImport.load(candidate: candidate, useSavedPieceStatus: !verifyData)
                    try QBittorrentImport.preflight(payload: payload)
                    return payload
                }.value
                guard !stopRequested, !Task.isCancelled else {
                    outcomes[candidate.id] = nil
                    break
                }
                guard let savedDestination = payload.candidate.destination,
                      let destination = destinationGrants[savedDestination.standardizedFileURL.path] else {
                    throw TorrentError.storage("The saved destination changed. Read the backup folder again.")
                }
                outcomes[candidate.id] = verifyData ? "Verifying existing data…" : "Importing saved progress…"
                let imported = try await engine.add(
                    metainfo: payload.metainfo, destination: destination,
                    selectedFiles: payload.candidate.selectedFiles,
                    seedRatio: payload.candidate.usesDefaultSeedRatio ? defaultSeedRatio : payload.candidate.seedRatio,
                    allowExisting: true, startPaused: true,
                    downloadedBytes: payload.candidate.downloadedBytes,
                    uploadedBytes: payload.candidate.uploadedBytes,
                    savedVerifiedPieces: payload.savedVerifiedPieces
                )
                existingIDs.insert(imported)
                selection.remove(candidate.id)
                importedCount += 1
                // add() can retain a failed verification for inspection in the library.
                let updates = await engine.snapshots()
                var iterator = updates.makeAsyncIterator()
                let snapshot = await iterator.next()?.first { $0.id == imported }
                if let snapshot, snapshot.state == .failed || snapshot.state == .unavailable {
                    outcomes[candidate.id] = "Added; needs attention: \(snapshot.error ?? snapshot.state.rawValue)"
                    failed += 1
                } else { outcomes[candidate.id] = "Imported · Paused" }
            } catch {
                outcomes[candidate.id] = error.localizedDescription
                failed += 1
            }
        }
        if failed > 0 { error = "\(failed) torrent\(failed == 1 ? " needs" : "s need") attention. See the status beside each torrent." }
    }

    func releaseAccess() {
        if sourceIsScoped, let sourceURL { sourceURL.stopAccessingSecurityScopedResource() }
        sourceIsScoped = false
        for url in scopedDestinations { url.stopAccessingSecurityScopedResource() }
        scopedDestinations = []; destinationGrants = [:]
    }
}

struct QBittorrentImportView: View {
    @Bindable var model: AppModel
    @Bindable var draft: QBittorrentImportDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from qBittorrent").font(.title2).bold()
            Text("Reuse your downloads in place and add the selected torrents paused.")
                .foregroundStyle(.secondary)
            HStack {
                Label(draft.sourceURL?.path ?? "Choose qBittorrent’s BT_backup folder", systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle).help(draft.sourceURL?.path ?? "")
                Spacer()
                Button("Choose Folder…", action: draft.chooseBackupFolder).disabled(draft.isScanning || draft.isImporting)
            }
            if draft.isScanning {
                HStack { ProgressView().controlSize(.small); Text("Reading saved torrents…"); Spacer(); Button("Cancel") { Task { await draft.cancelScanning() } } }
            }
            HStack {
                TextField("Search torrents or destinations", text: $draft.search).textFieldStyle(.roundedBorder)
                Text("\(draft.selection.count) selected / \(draft.candidates.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            Table(draft.visibleCandidates) {
                TableColumn("") { candidate in
                    Toggle("Import \(candidate.name)", isOn: Binding(
                        get: { draft.selection.contains(candidate.id) },
                        set: { if $0 { draft.selection.insert(candidate.id) } else { draft.selection.remove(candidate.id) } }
                    ))
                    .labelsHidden()
                    .disabled(draft.isImporting || !draft.canSelect(candidate))
                }.width(28)
                TableColumn("Torrent") { candidate in Text(candidate.name).lineLimit(1).help(candidate.name) }.width(min: 180, ideal: 250, max: 280)
                TableColumn("Size") { candidate in Text(candidate.totalBytes.map(byteString) ?? "—").monospacedDigit() }.width(80)
                TableColumn("Destination") { candidate in Text(candidate.destination?.path ?? "—").lineLimit(1).truncationMode(.middle).help(candidate.destination?.path ?? "") }.width(190)
                TableColumn("Status") { candidate in Text(draft.status(candidate)).lineLimit(1).truncationMode(.tail).help(draft.status(candidate)).foregroundStyle(draft.canSelect(candidate) ? Color.primary : Color.secondary) }.width(200)
            }
            .overlay {
                if draft.candidates.isEmpty && !draft.isScanning {
                    ContentUnavailableView("Choose a Backup Folder", systemImage: "tray.and.arrow.down", description: Text("Usually in ~/Library/Application Support/qBittorrent/BT_backup."))
                }
            }
            HStack {
                Button("Select Shown", action: draft.selectVisible)
                Button("Select None") { draft.selection = [] }
                Spacer()
                if draft.importedCount > 0 { Text("\(draft.importedCount) imported").foregroundStyle(.secondary) }
            }.disabled(draft.isImporting || draft.isScanning)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Verify existing data", isOn: $draft.verifyExistingData)
                    .toggleStyle(.checkbox).disabled(draft.isImporting)
                Text(draft.verifyExistingData
                     ? "Check file contents before importing. Turn off to import faster using qBittorrent’s saved progress."
                     : "Use qBittorrent’s saved progress without checking file contents. Files should be unchanged since that progress was saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Pause these torrents in qBittorrent before importing. Saved file selections and transfer totals are preserved. Inherited ratio limits use Torrenza’s default.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = draft.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if draft.isImporting {
                    ProgressView().controlSize(.small)
                    Text(draft.progress).lineLimit(1).truncationMode(.middle).help(draft.progress)
                    Spacer()
                    Button(draft.stopRequested ? "Stopping after current…" : "Stop After Current") { draft.stopRequested = true }.disabled(draft.stopRequested)
                } else {
                    Spacer()
                    Button("Done", action: model.closeQBittorrentImport).keyboardShortcut(.cancelAction).disabled(draft.isScanning)
                    Button("Import Selected") { model.finishQBittorrentImport(draft) }
                        .keyboardShortcut(.defaultAction).disabled(draft.selection.isEmpty || draft.isScanning)
                }
            }
        }
        .padding(24).frame(width: 940, height: 620)
        .interactiveDismissDisabled()
    }
}
