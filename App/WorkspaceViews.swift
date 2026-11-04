import SwiftUI
import TorrentCore
import TorrentEngine

/// Central panel header: selected filter title, search-results summary, the
/// filter menu while the sidebar is hidden, and the live search field.
struct CentralPanelHeader: View {
    @Bindable var model: AppModel
    let visibleCount: Int

    private var searchIsActive: Bool { !model.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: WorkspaceMetrics.space3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.filter.rawValue)
                    .font(.system(size: WorkspaceMetrics.contentFontSize, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if searchIsActive {
                    Text("\(visibleCount) of \(model.filterCounts[model.filter] ?? 0) shown")
                        .font(.system(size: WorkspaceMetrics.metadataFontSize))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
            if !model.isSidebarVisible {
                Menu {
                    Picker("Filter", selection: $model.filter) {
                        ForEach(TreeFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                } label: {
                    Label(model.filter.rawValue, systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderedButton)
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("Filter transfers")
            }
            Spacer(minLength: WorkspaceMetrics.space3)
            PanelSearchField(text: $model.search, focusRequest: model.searchFocusRequest)
                .frame(width: WorkspaceMetrics.searchFieldWidth)
                .disabled(!model.isProfileReady || model.isSwitchingProfile)
        }
        .padding(.horizontal, WorkspaceMetrics.space4)
        .padding(.vertical, WorkspaceMetrics.space3)
    }
}

/// The live native search field, now hosted in the central panel header.
/// Search stays live and keeps its clear action and Cmd-F focus behavior.
struct PanelSearchField: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focusRequest: focusRequest) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search torrents and files"
        field.controlSize = .small
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.setAccessibilityLabel("Search torrents and files")
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        field.isEnabled = context.environment.isEnabled
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            if field.isEnabled { field.window?.makeFirstResponder(field); field.selectText(nil) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? WorkspaceMetrics.searchFieldWidth, height: 24)
    }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var focusRequest: Int
        init(text: Binding<String>, focusRequest: Int) { self.text = text; self.focusRequest = focusRequest }
        @objc func searchChanged(_ field: NSSearchField) { text.wrappedValue = field.stringValue }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// Empty profile: the first-run invitation with the primary Add action.
struct EmptyLibraryView: View {
    let openFile: () -> Void
    let openURL: () -> Void
    let openMagnet: () -> Void
    let importQBittorrent: () -> Void

    var body: some View {
        VStack(spacing: WorkspaceMetrics.space3) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("Add Your First Torrent")
                .font(.system(size: WorkspaceMetrics.contentFontSize, weight: .semibold))
            Text("Open a torrent or magnet link. Your downloads will appear in their folders.")
                .font(.system(size: WorkspaceMetrics.metadataFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: WorkspaceMetrics.space2) {
                Button {
                    openFile()
                } label: {
                    Label("Add Torrent…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.torrenzaPrimaryAction)
                .foregroundStyle(Color.torrenzaPrimaryActionText)
                Menu("More") {
                    Button("Open Torrent URL…", action: openURL)
                    Button("Open Magnet Link…", action: openMagnet)
                    Button("Import from qBittorrent…", action: importQBittorrent)
                }
                .menuStyle(.borderedButton)
                .controlSize(.regular)
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(WorkspaceMetrics.space6)
    }
}

/// A selected filter with zero transfers.
struct EmptyFilterView: View {
    let filter: TreeFilter
    let showAll: () -> Void

    var body: some View {
        VStack(spacing: WorkspaceMetrics.space2) {
            Text("No \(filter.rawValue.lowercased()) Transfers")
                .font(.system(size: WorkspaceMetrics.contentFontSize, weight: .semibold))
            Text("Nothing in this profile matches “\(filter.rawValue)” right now.")
                .font(.system(size: WorkspaceMetrics.metadataFontSize))
                .foregroundStyle(.secondary)
            Button("Show All Transfers", action: showAll)
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(WorkspaceMetrics.space6)
    }
}

/// A search with no matches.
struct EmptySearchResultsView: View {
    let query: String
    let clear: () -> Void

    var body: some View {
        VStack(spacing: WorkspaceMetrics.space2) {
            Text("No Results for “\(query)”")
                .font(.system(size: WorkspaceMetrics.contentFontSize, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("No torrents or files match this search.")
                .font(.system(size: WorkspaceMetrics.metadataFontSize))
                .foregroundStyle(.secondary)
            Button("Clear Search", action: clear)
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(WorkspaceMetrics.space6)
    }
}

/// Compact bottom status shelf. Metrics always describe the whole active
/// profile; search and filters never change their scope. At constrained
/// widths the session totals hide before the live rates compress; the totals
/// stay available through the accessibility summary and help text.
struct StatusShelfView: View {
    @Bindable var model: AppModel
    @State private var width: CGFloat = 900

    var body: some View {
        let transfers = model.transfers
        let downloadRate = transfers.reduce(0.0) { $0 + $1.downloadRate }
        let uploadRate = transfers.reduce(0.0) { $0 + $1.uploadRate }
        HStack(spacing: WorkspaceMetrics.space4) {
            Text("\(transfers.count) transfers · \(model.activeCount) active")
                .help("The active profile contains \(transfers.count) transfers; \(model.activeCount) are downloading or seeding.")
            Spacer(minLength: WorkspaceMetrics.space4)
            if let stats = model.statistics, width >= 720 {
                Text("Session ↓ \(byteString(stats.current.downloadedBytes)) ↑ \(byteString(stats.current.uploadedBytes))")
                    .help(sessionHelp(stats))
                    .accessibilityLabel("Current session downloaded \(byteString(stats.current.downloadedBytes)), uploaded \(byteString(stats.current.uploadedBytes))")
            }
            HStack(spacing: WorkspaceMetrics.space3) {
                Label(rateString(downloadRate), systemImage: "arrow.down")
                    .help("Total download rate for the whole profile")
                Label(rateString(uploadRate), systemImage: "arrow.up")
                    .help("Total upload rate for the whole profile")
            }
        }
        .font(.system(size: WorkspaceMetrics.metadataFontSize))
        .monospacedDigit()
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(.secondary)
        .padding(.horizontal, WorkspaceMetrics.space4)
        .frame(height: WorkspaceMetrics.shelfHeight)
        .background(Color.torrenzaRecessed, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.groupRadius + 2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceMetrics.groupRadius + 2, style: .continuous)
                .strokeBorder(Color.torrenzaBorder, lineWidth: WorkspaceMetrics.hairline)
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shelfAccessibilitySummary)
    }

    private func sessionHelp(_ stats: StatisticsSnapshot) -> String {
        "Lifetime downloaded: \(byteString(stats.lifetimeDownloadedBytes)). Lifetime uploaded: \(byteString(stats.lifetimeUploadedBytes))."
    }

    private var shelfAccessibilitySummary: String {
        var summary = "\(model.transfers.count) transfers, \(model.activeCount) active."
        if let stats = model.statistics {
            summary += " Current session downloaded \(byteString(stats.current.downloadedBytes)), uploaded \(byteString(stats.current.uploadedBytes))."
        }
        return summary
    }
}
