import SwiftUI
import TorrentEngine

/// Library filter sidebar. A single section of filters with torrent counts.
/// Counts always describe the whole profile, independent of search.
struct LibrarySidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        PanelContainer {
            VStack(alignment: .leading, spacing: WorkspaceMetrics.space2) {
                Text("Library")
                    .font(.system(size: WorkspaceMetrics.contentFontSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, WorkspaceMetrics.space4)
                    .padding(.top, WorkspaceMetrics.space4)
                VStack(spacing: 2) {
                    let counts = model.filterCounts
                    ForEach(TreeFilter.allCases, id: \.self) { filter in
                        SidebarFilterRow(
                            filter: filter,
                            count: counts[filter] ?? 0,
                            isSelected: model.filter == filter
                        ) {
                            model.filter = filter
                        }
                    }
                }
                .padding(.horizontal, WorkspaceMetrics.space2)
                .padding(.bottom, WorkspaceMetrics.space2)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library filters")
    }
}

private struct SidebarFilterRow: View {
    let filter: TreeFilter
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    private var symbol: String {
        switch filter {
        case .all: "tray.2"
        case .active: "bolt"
        case .downloading: "arrow.down.circle"
        case .completed: "checkmark.circle"
        case .paused: "pause.circle"
        case .attention: "exclamationmark.triangle"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: WorkspaceMetrics.space2) {
                Image(systemName: symbol)
                    .imageScale(.medium)
                    .frame(width: 18)
                    .foregroundStyle(symbolForeground)
                    .accessibilityHidden(true)
                Text(filter.rawValue)
                    .font(.system(size: WorkspaceMetrics.contentFontSize))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: WorkspaceMetrics.space2)
                Text(count.formatted())
                    .font(.system(size: WorkspaceMetrics.metadataFontSize))
                    .monospacedDigit()
                    .frame(minWidth: 34, alignment: .trailing)
                    .foregroundStyle(isSelected ? Color.torrenzaSelectionText.opacity(0.8) : Color.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, WorkspaceMetrics.space2)
            .frame(height: WorkspaceMetrics.sidebarRowHeight)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: WorkspaceMetrics.groupRadius, style: .continuous)
                        .fill(Color.torrenzaSelection)
                }
            }
            .foregroundStyle(isSelected ? Color.torrenzaSelectionText : Color.primary)
            .contentShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.groupRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel("\(filter.rawValue), \(count) transfer\(count == 1 ? "" : "s")")
        .accessibilityHint(isSelected ? "Currently selected filter" : "Shows these transfers in the list")
    }

    /// One leading symbol per row: the shared violet accent for ordinary
    /// filters, semantic amber for Needs Attention.
    private var symbolForeground: Color {
        if filter == .attention { return .orange }
        return isSelected ? Color.torrenzaSelectionText : Color.torrenzaAccent
    }
}
