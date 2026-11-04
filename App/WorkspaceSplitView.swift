import AppKit
import SwiftUI
import TorrentEngine

/// The workspace split. NSSplitView hosts the panes because SwiftUI's
/// HSplitView cannot honor saved pane widths: it grows bounded panes straight
/// to their maxima. Panes are installed once, in fixed order, and toggled with
/// `isHidden`, so hiding or showing a panel never rebuilds the tree. Layout is
/// frame-based: auxiliary panes keep their widths, the tree absorbs window
/// resizes, and a shrinking window takes the auxiliary panes toward their
/// minima before the tree compresses. Panes cannot collapse by dragging;
/// visibility changes only through the explicit toggles.
struct WorkspaceSplitView<S: View, C: View, I: View>: NSViewRepresentable {
    let model: AppModel
    let sidebarVisible: Bool
    let sidebarWidth: Double
    let inspectorVisible: Bool
    let inspectorWidth: Double
    let layoutToken: UUID
    @ViewBuilder let sidebar: () -> S
    @ViewBuilder let central: () -> C
    @ViewBuilder let inspector: () -> I

    func makeCoordinator() -> Coordinator { Coordinator(model: model, token: layoutToken) }

    func makeNSView(context: Context) -> WorkspaceNSSplitView {
        let split = WorkspaceNSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = nil
        split.delegate = context.coordinator
        context.coordinator.attach(split: split)
        context.coordinator.update(
            sidebarVisible: sidebarVisible, sidebarWidth: sidebarWidth,
            inspectorVisible: inspectorVisible, inspectorWidth: inspectorWidth,
            layoutToken: layoutToken,
            sidebar: AnyView(sidebar()), central: AnyView(central()), inspector: AnyView(inspector()))
        return split
    }

    func updateNSView(_ view: WorkspaceNSSplitView, context: Context) {
        context.coordinator.update(
            sidebarVisible: sidebarVisible, sidebarWidth: sidebarWidth,
            inspectorVisible: inspectorVisible, inspectorWidth: inspectorWidth,
            layoutToken: layoutToken,
            sidebar: AnyView(sidebar()), central: AnyView(central()), inspector: AnyView(inspector()))
    }

    /// Fill the proposal instead of the panes' fitted content size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WorkspaceNSSplitView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.fittingSize.width,
               height: proposal.height ?? nsView.fittingSize.height)
    }

    @MainActor final class Coordinator: NSObject, NSSplitViewDelegate {
        let model: AppModel
        /// Tracks the active profile's layout generation. Unlike the split,
        /// the coordinator survives profile switches, so the token must be
        /// refreshed whenever a new profile's layout arrives.
        var token: UUID
        /// True while an incoming profile's layout is being applied. Width
        /// reporting is suppressed so restoration cannot save partially
        /// applied geometry — or the previous profile's panes — into the new
        /// profile's state.
        private var applyingProfileLayout = false
        weak var split: WorkspaceNSSplitView?
        var sidebarHost: NSHostingView<AnyView>?
        var centralHost: NSHostingView<AnyView>?
        var inspectorHost: NSHostingView<AnyView>?

        init(model: AppModel, token: UUID) {
            self.model = model
            self.token = token
        }

        func attach(split: WorkspaceNSSplitView) {
            self.split = split
            split.onPaneLayout = { [weak self] in self?.reportPaneWidths() }
        }

        private func install(_ host: NSHostingView<AnyView>, in split: NSSplitView,
                             before reference: NSView?, savedWidth: Double) {
            // Frame-based panes: the split owns their geometry directly, and
            // hosted content does not push its own size.
            host.frame = NSRect(x: 0, y: 0, width: CGFloat(savedWidth), height: 0)
            host.sizingOptions = []
            if let reference { split.addSubview(host, positioned: .below, relativeTo: reference) }
            else { split.addArrangedSubview(host) }
        }

        /// Reports pane widths with the token and measurements captured
        /// together, so a deferred invocation can never pair a newer token
        /// with an older measurement.
        private func reportPaneWidths() {
            guard !applyingProfileLayout, let split, split.bounds.width > 100 else { return }
            let activeToken = token
            if let sidebarHost, !sidebarHost.isHidden {
                let width = Double(sidebarHost.bounds.width)
                model.reportSidebarWidth(width, token: activeToken)
            }
            if let inspectorHost, !inspectorHost.isHidden {
                let width = Double(inspectorHost.bounds.width)
                model.reportInspectorWidth(width, token: activeToken)
            }
        }

        func update(sidebarVisible: Bool, sidebarWidth: Double,
                    inspectorVisible: Bool, inspectorWidth: Double,
                    layoutToken: UUID,
                    sidebar: AnyView, central: AnyView, inspector: AnyView) {
            guard let split else { return }
            // Adopt the incoming profile's token before touching pane
            // geometry, and hold off reporting until the restore settles.
            if token != layoutToken {
                token = layoutToken
                applyingProfileLayout = true
            }
            defer { applyingProfileLayout = false }
            if centralHost == nil {
                let host = NSHostingView<AnyView>(rootView: central)
                install(host, in: split, before: nil, savedWidth: 0)
                centralHost = host
            } else { centralHost?.rootView = central }
            if sidebarHost == nil {
                let host = NSHostingView<AnyView>(rootView: sidebar)
                // Fixed order: sidebar, tree, inspector.
                install(host, in: split, before: centralHost,
                        savedWidth: WorkspaceMetrics.clamp(sidebarWidth, min: WorkspaceMetrics.sidebarMinWidth, max: WorkspaceMetrics.sidebarMaxWidth))
                sidebarHost = host
            }
            if let sidebarHost { sidebarHost.rootView = sidebar }
            if inspectorHost == nil {
                let host = NSHostingView<AnyView>(rootView: inspector)
                install(host, in: split, before: nil,
                        savedWidth: WorkspaceMetrics.clamp(inspectorWidth, min: WorkspaceMetrics.inspectorMinWidth, max: WorkspaceMetrics.inspectorMaxWidth))
                inspectorHost = host
            }
            if let inspectorHost { inspectorHost.rootView = inspector }

            let sidebarChanged = sidebarHost?.isHidden != !sidebarVisible
            let inspectorChanged = inspectorHost?.isHidden != !inspectorVisible
            sidebarHost?.isHidden = !sidebarVisible
            inspectorHost?.isHidden = !inspectorVisible

            // Widths that changed outside this split (restored preferences)
            // move the panes; sizes produced by local drags already match.
            // Restores also respect the space the tree needs: the auxiliary
            // panes give way from the trailing edge first.
            if let sidebarHost, !sidebarHost.isHidden,
               abs(Double(sidebarHost.bounds.width) - sidebarWidth) > 1.5 {
                split.savedSidebarWidth = CGFloat(WorkspaceMetrics.clamp(sidebarWidth, min: WorkspaceMetrics.sidebarMinWidth, max: WorkspaceMetrics.sidebarMaxWidth))
                sidebarHost.frame.size.width = split.savedSidebarWidth
                split.needsPaneLayout = true
            }
            if let inspectorHost, !inspectorHost.isHidden,
               abs(Double(inspectorHost.bounds.width) - inspectorWidth) > 1.5 {
                split.savedInspectorWidth = CGFloat(WorkspaceMetrics.clamp(inspectorWidth, min: WorkspaceMetrics.inspectorMinWidth, max: WorkspaceMetrics.inspectorMaxWidth))
                inspectorHost.frame.size.width = split.savedInspectorWidth
                split.needsPaneLayout = true
            }
            if split.needsPaneLayout, split.bounds.width > 100 {
                let budget = split.bounds.width - split.dividerThickness * 2 - WorkspaceMetrics.centralMinWidth
                let over = split.savedSidebarWidth + split.savedInspectorWidth - budget
                if over > 0, sidebarHost?.isHidden == false, inspectorHost?.isHidden == false {
                    let inspectorRoom = split.savedInspectorWidth - WorkspaceMetrics.inspectorMinWidth
                    split.savedInspectorWidth -= min(inspectorRoom, over)
                    let sidebarRoom = split.savedSidebarWidth - WorkspaceMetrics.sidebarMinWidth
                    split.savedSidebarWidth -= min(sidebarRoom, max(0, over - inspectorRoom))
                    inspectorHost?.frame.size.width = split.savedInspectorWidth
                    sidebarHost?.frame.size.width = split.savedSidebarWidth
                }
            }
            if sidebarChanged || inspectorChanged { split.needsPaneLayout = true }
            if split.needsPaneLayout { split.layoutPanes() }
        }

        // MARK: NSSplitViewDelegate

        func splitViewDidResize(_ notification: Notification) {
            reportPaneWidths()
        }

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            (splitView as? WorkspaceNSSplitView)?.layoutPanes()
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumCoordinate: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            guard let split = splitView as? WorkspaceNSSplitView else { return proposedMinimumCoordinate }
            return split.minimumDividerPosition(dividerIndex)
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumCoordinate: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            guard let split = splitView as? WorkspaceNSSplitView else { return proposedMaximumCoordinate }
            return split.maximumDividerPosition(dividerIndex)
        }

        func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            guard let split = splitView as? WorkspaceNSSplitView else { return proposedPosition }
            return min(max(proposedPosition, split.minimumDividerPosition(dividerIndex)), split.maximumDividerPosition(dividerIndex))
        }
    }
}

/// A split view that owns its pane frames. Divider positions come from pane
/// widths; bounds changes re-place the panes through `layoutPanes()`. Divider
/// regions are 12-point canvas gutters: the visible rule is suppressed, but
/// the whole region stays a resize target with the split cursor.
final class WorkspaceNSSplitView: NSSplitView {
    var savedSidebarWidth: CGFloat = WorkspaceMetrics.sidebarIdealWidth
    var savedInspectorWidth: CGFloat = WorkspaceMetrics.inspectorIdealWidth
    var needsPaneLayout = false
    /// Fires after any pane relayout — divider drags, programmatic positions,
    /// and window resizes — so width reports never miss a change.
    var onPaneLayout: (() -> Void)?

    override var dividerThickness: CGFloat { WorkspaceMetrics.dividerThickness }

    /// Canvas shows through the divider region; no visible rule is drawn.
    override func drawDivider(in rect: NSRect) {}

    override func adjustSubviews() {
        super.adjustSubviews()
        onPaneLayout?()
    }

    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        super.setPosition(position, ofDividerAt: dividerIndex)
        onPaneLayout?()
    }

    override func layout() {
        super.layout()
        onPaneLayout?()
    }

    private var sidebarVisible: Bool { arrangedSubviews.count > 1 && arrangedSubviews.first?.isHidden == false }
    private var inspectorVisible: Bool { arrangedSubviews.count > 2 && arrangedSubviews.last?.isHidden == false }
    private var visiblePanes: [NSView] { arrangedSubviews.filter { !$0.isHidden } }
    private var treeIndex: Int? {
        let panes = visiblePanes
        guard !panes.isEmpty else { return nil }
        return sidebarVisible ? 1 : 0
    }

    /// Places visible panes left to right from their current widths; the tree
    /// takes the remainder, and only compresses after the auxiliary panes have
    /// reached their minima.
    func layoutPanes() {
        needsPaneLayout = false
        let panes = visiblePanes
        guard bounds.width > 0, !panes.isEmpty else { return }
        let thickness = dividerThickness
        let available = bounds.width - thickness * CGFloat(panes.count - 1)
        var widths = panes.map { $0.bounds.width }
        if let tree = treeIndex {
            for (index, pane) in panes.enumerated() where index != tree {
                if widths[index] < 1 { widths[index] = index == 0 ? savedSidebarWidth : savedInspectorWidth }
            }
            widths[tree] = 0
            let auxiliary = widths.enumerated().filter { $0.offset != tree }.reduce(CGFloat(0)) { $0 + $1.element }
            widths[tree] = max(0, available - auxiliary)
            if widths[tree] < WorkspaceMetrics.centralMinWidth {
                // Take the auxiliary panes toward their minima first.
                let deficit = WorkspaceMetrics.centralMinWidth - widths[tree]
                var remaining = deficit
                for index in widths.indices where index != tree {
                    let room = widths[index] - minimumWidth(at: index, in: panes)
                    let take = min(max(0, room), remaining)
                    widths[index] -= take
                    remaining -= take
                    if remaining <= 0 { break }
                }
                var auxiliary: CGFloat = 0
                for index in widths.indices where index != tree { auxiliary += widths[index] }
                widths[tree] = max(0, available - auxiliary)
            }
        }
        var x: CGFloat = 0
        for (index, pane) in panes.enumerated() {
            pane.frame = NSRect(x: x, y: 0, width: widths[index], height: bounds.height)
            x += widths[index] + thickness
        }
    }

    /// Minimum width of the visible pane at `index`, in the visible order
    /// [sidebar?, tree, inspector?].
    private func minimumWidth(at index: Int, in panes: [NSView]) -> CGFloat {
        if sidebarVisible {
            if index == 0 { return WorkspaceMetrics.sidebarMinWidth }
            return index == 1 ? WorkspaceMetrics.centralMinWidth : WorkspaceMetrics.inspectorMinWidth
        }
        if inspectorVisible {
            return index == 0 ? WorkspaceMetrics.centralMinWidth : WorkspaceMetrics.inspectorMinWidth
        }
        return 0
    }

    /// Maximum width of the visible pane at `index`, for bounded auxiliary panes.
    private func maximumWidth(at index: Int) -> CGFloat {
        if index == 0, sidebarVisible { return WorkspaceMetrics.sidebarMaxWidth }
        if !sidebarVisible, inspectorVisible, index == 1 { return WorkspaceMetrics.inspectorMaxWidth }
        if sidebarVisible, inspectorVisible, index == 2 { return WorkspaceMetrics.inspectorMaxWidth }
        return .greatestFiniteMagnitude
    }

    private func leadingOrigin(of dividerIndex: Int) -> CGFloat {
        let panes = visiblePanes
        guard dividerIndex < panes.count else { return 0 }
        var x: CGFloat = 0
        for (index, pane) in panes.enumerated() where index < dividerIndex {
            x += pane.bounds.width + dividerThickness
        }
        return x
    }

    func minimumDividerPosition(_ dividerIndex: Int) -> CGFloat {
        leadingOrigin(of: dividerIndex) + minimumWidth(at: dividerIndex, in: visiblePanes)
    }

    func maximumDividerPosition(_ dividerIndex: Int) -> CGFloat {
        let panes = visiblePanes
        guard dividerIndex < panes.count - 1 else { return bounds.width }
        var trailing: CGFloat = 0
        for index in (dividerIndex + 1)..<panes.count {
            trailing += minimumWidth(at: index, in: panes) + dividerThickness
        }
        let trailingFloor = bounds.width - trailing
        return min(leadingOrigin(of: dividerIndex) + maximumWidth(at: dividerIndex), trailingFloor)
    }
}
