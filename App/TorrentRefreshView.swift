import Foundation
import Observation
import SwiftUI
import TorrentCore
import WebKit

@MainActor @Observable final class TorrentRefreshSourceDraft: Identifiable {
    enum Purpose { case transfer(id: String, refreshAfterSave: Bool), newImport }
    let id = UUID()
    let purpose: Purpose
    var sourceText: String
    var error: String?
    var isSaving = false
    init(purpose: Purpose, sourceText: String = "") { self.purpose = purpose; self.sourceText = sourceText }
}

@MainActor @Observable final class TorrentRefreshOperation: Identifiable {
    let id = UUID()
    let title: String
    let fetcher: TorrentRefreshFetcher
    var status = "Fetching torrent…"
    var isWorking = true
    var isApplying = false
    var error: String?
    var importedMetainfo: TorrentMetainfo?
    var selectionMetainfo: TorrentMetainfo?
    var selectedFiles: Set<Int> = []
    var replacingID: String?
    init(title: String, profileID: String) {
        self.title = title
        #if DEBUG
        let isolated = ProcessInfo.processInfo.arguments.contains("--ui-fixture") || ProcessInfo.processInfo.arguments.contains("--refresh-fetch-smoke")
        fetcher = TorrentRefreshFetcher(profileID: profileID, websiteDataStore: isolated ? .nonPersistent() : nil)
        #else
        fetcher = TorrentRefreshFetcher(profileID: profileID)
        #endif
    }
}

struct TorrentRefreshSourceView: View {
    @Bindable var model: AppModel
    @Bindable var draft: TorrentRefreshSourceDraft
    private var isImport: Bool { if case .newImport = draft.purpose { true } else { false } }
    private var actionTitle: String {
        switch draft.purpose {
        case .newImport: "Fetch Torrent"
        case .transfer(_, let refreshAfterSave): refreshAfterSave ? "Save and Refresh" : "Save"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.space4) {
            SheetHeader(
                title: isImport ? "Open Torrent URL" : "Torrent Refresh Source",
                subtitle: "Enter the RuTracker topic link or a direct .torrent download URL. Torrenza remembers it for future refreshes.",
                systemImage: "arrow.clockwise.circle"
            )
            TextField("https://rutracker.org/forum/viewtopic.php?t=…", text: $draft.sourceText)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Torrent source URL")
                .onSubmit { model.saveRefreshSource() }
            if let error = draft.error {
                NoticeView(kind: .error, title: "Could not save the source", message: error)
            }
            SheetFooter {
                if draft.isSaving { ProgressView().controlSize(.small) }
            } actions: {
                Button("Cancel") { model.refreshSourceEditor = nil }.keyboardShortcut(.cancelAction)
                Button(actionTitle, action: model.saveRefreshSource)
                    .keyboardShortcut(.defaultAction).disabled(draft.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(WorkspaceMetrics.space4)
        .frame(width: 540)
        .disabled(draft.isSaving)
        .interactiveDismissDisabled(draft.isSaving)
    }
}

struct TorrentRefreshProgressView: View {
    @Bindable var model: AppModel
    @Bindable var operation: TorrentRefreshOperation
    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.space3) {
            SheetHeader(title: operation.title, systemImage: "arrow.clockwise.circle")
            if operation.fetcher.isAuthenticationRequired && operation.isWorking {
                RuTrackerLoginView(fetcher: operation.fetcher)
            } else {
                HStack(spacing: WorkspaceMetrics.space2) {
                    if operation.isWorking { ProgressView().controlSize(.small) }
                    Text(operation.status)
                }
                if let error = operation.error {
                    NoticeView(kind: .error, title: "Could not refresh torrent", message: error)
                }
                if let metainfo = operation.selectionMetainfo {
                    List(metainfo.files.filter { !$0.isPadding }) { file in
                        Toggle(isOn: Binding(get: { operation.selectedFiles.contains(file.index) }, set: { selected in
                            if selected { operation.selectedFiles.insert(file.index) } else { operation.selectedFiles.remove(file.index) }
                        })) {
                            HStack {
                                Text(file.path.dropFirst().joined(separator: "/")).lineLimit(1).truncationMode(.middle)
                                    .help(file.path.joined(separator: "/"))
                                Spacer()
                                Text(byteString(file.length)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .toggleStyle(.checkbox)
                    }.frame(height: 220)
                }
            }
            if !operation.fetcher.isAuthenticationRequired {
                SheetFooter {
                    EmptyView()
                } actions: {
                    if operation.isWorking {
                        Button("Cancel", action: model.cancelTorrentRefresh).keyboardShortcut(.cancelAction)
                    } else if operation.selectionMetainfo != nil {
                        Button("Cancel", action: model.dismissTorrentRefresh).keyboardShortcut(.cancelAction)
                        Button("Apply Update", action: model.applyRefreshFileSelection).keyboardShortcut(.defaultAction)
                            .disabled(operation.selectedFiles.isEmpty)
                    } else {
                        Button("Done", action: model.dismissTorrentRefresh).keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(WorkspaceMetrics.space4)
        .frame(width: operation.fetcher.isAuthenticationRequired ? 780 : 540)
        .interactiveDismissDisabled()
    }
}
