import AppKit
import TorrentCore
import TorrentEngine

/// Paints the workspace's rounded lavender selection through AppKit's
/// dedicated row drawing hooks. The outline uses `.regular` selection
/// highlighting so clicks and keyboard selection go through the native path;
/// `drawSelection(in:)` replaces the default painter with the palette fill,
/// and `interiorBackgroundStyle` stays `.normal` so the pale custom fill does
/// not trigger the emphasized white foreground treatment.
final class TorrentTableRowView: NSTableRowView {
    /// Hover tracking is disabled while diagnostics drive synthetic events:
    /// AppKit can route enter/exit events at recycled row views mid-teardown.
    static var hoverTrackingEnabled = true

    /// Removes every installed hover area from the given outline's rows.
    static func suspendHoverTracking(in outline: NSOutlineView) {
        hoverTrackingEnabled = false
        for case let row as TorrentTableRowView in outline.subviews {
            row.clearHoverTracking()
        }
    }

    private func clearHoverTracking() {
        hovered = false
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
    }

    private var hovered = false

    /// Selection fill geometry: the highlight spans the whole row.
    private var selectionRect: NSRect { bounds.insetBy(dx: 3, dy: 2) }

    override func drawSelection(in dirtyRect: NSRect) {
        // Do not call super: the default painter uses system selection colors.
        guard isSelected else { return }
        // A key window shows the full lavender fill; an inactive window keeps
        // the selection recognizable without competing for attention.
        let fill = (isEmphasized ? Palette.selectionFill : Palette.selectionFillInactive)
            .resolved(in: effectiveAppearance)
        fill.setFill()
        NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        // Hover is weaker than selection and never overlays it.
        guard hovered, !isSelected else { return }
        Palette.rowHover.resolved(in: effectiveAppearance).setFill()
        NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6).fill()
    }

    /// The custom pale selection must not recolor row content; explicit
    /// warning and error foregrounds stay readable on top of it.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override var isSelected: Bool {
        didSet { if oldValue != isSelected { needsDisplay = true } }
    }

    override var isEmphasized: Bool {
        didSet { if oldValue != isEmphasized { needsDisplay = true } }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // Recycled row views must not leave tracking areas behind: AppKit can
        // dispatch hover events to a deallocated owner.
        if newWindow == nil {
            for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        guard Self.hoverTrackingEnabled else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        if !isSelected { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        if !isSelected { needsDisplay = true }
    }
}

/// A quiet determinate progress track. It draws once per state change; there
/// is no continuous animation. The tint can be dialed down for paused or
/// queued work.
final class ProgressTrackView: NSView {
    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }
    var showsFill = true {
        didSet { needsDisplay = true }
    }
    /// Determinate fill color, resolved at draw time.
    var fillColor: NSColor = Palette.accent {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let appearance = effectiveAppearance
        let trackBounds = bounds
        let track = NSBezierPath(roundedRect: trackBounds, xRadius: trackBounds.height / 2, yRadius: trackBounds.height / 2)
        Palette.recessed.resolved(in: appearance).setFill()
        track.fill()
        guard showsFill, fraction > 0 else { return }
        var fillRect = trackBounds
        fillRect.size.width = max(trackBounds.height, trackBounds.width * CGFloat(min(max(fraction, 0), 1)))
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: trackBounds.height / 2, yRadius: trackBounds.height / 2)
        fillColor.resolved(in: appearance).setFill()
        fill.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Reusable Progress / Status cell. Torrent rows stack a readable
/// status-and-percentage line over a quiet track; text-only rows such as
/// "No files selected", "Skipped", and aggregate percentages center their
/// text with no track. Every configure call resets all visual state, so
/// reused cells cannot leak a previous row's presentation.
final class TorrentProgressCellView: NSTableCellView {
    let track = ProgressTrackView()
    let statusText = NSTextField(labelWithString: "")
    private var stackedConstraints: [NSLayoutConstraint] = []
    private var centeredConstraints: [NSLayoutConstraint] = []
    private let trackHeight: CGFloat = 4
    private let textTrackGap: CGFloat = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        track.translatesAutoresizingMaskIntoConstraints = false
        statusText.translatesAutoresizingMaskIntoConstraints = false
        statusText.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusText.lineBreakMode = .byTruncatingTail
        addSubview(statusText)
        addSubview(track)
        // `textField` carries the status text so accessibility and help keep
        // working through the standard cell machinery.
        textField = statusText
        // Stacked: the status line sits above a 4-point track, and the whole
        // block centers in the row by shifting up half the track stack.
        stackedConstraints = [
            statusText.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            statusText.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            statusText.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -(trackHeight + textTrackGap) / 2),
            track.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            track.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            track.heightAnchor.constraint(equalToConstant: trackHeight),
            track.topAnchor.constraint(equalTo: statusText.bottomAnchor, constant: textTrackGap)
        ]
        centeredConstraints = [
            statusText.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            statusText.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            statusText.centerYAnchor.constraint(equalTo: centerYAnchor)
        ]
        NSLayoutConstraint.activate(stackedConstraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Unsupported") }

    func configure(fraction: Double?, text: String, tint: NSColor, trackTint: NSColor = Palette.accent) {
        track.showsFill = fraction != nil
        track.fraction = fraction ?? 0
        track.fillColor = trackTint
        statusText.stringValue = text
        statusText.textColor = tint
    }

    /// Text-only presentations drop the track and center the text; stacked
    /// rows place the status line above the track.
    func setTrackHidden(_ hidden: Bool) {
        guard track.isHidden != hidden else { return }
        track.isHidden = hidden
        if hidden {
            NSLayoutConstraint.deactivate(stackedConstraints)
            NSLayoutConstraint.activate(centeredConstraints)
        } else {
            NSLayoutConstraint.deactivate(centeredConstraints)
            NSLayoutConstraint.activate(stackedConstraints)
        }
        needsLayout = true
    }
}
