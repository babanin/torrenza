import AppKit
import TorrentCore
import TorrentEngine

/// Draws the workspace's rounded lavender selection and quiet hover directly,
/// with a muted fill when the window is not key. The outline uses
/// `selectionHighlightStyle = .none`, so text colors stay readable on the pale
/// fill and this view owns all selection drawing.
final class TorrentTableRowView: NSTableRowView {
    private var hovered = false
    private var keyObservers: [NSObjectProtocol] = []

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        for observer in keyObservers { NotificationCenter.default.removeObserver(observer) }
        keyObservers = []
        if let newWindow {
            keyObservers = [
                NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: newWindow, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.needsDisplay = true }
                },
                NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: newWindow, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.needsDisplay = true }
                }
            ]
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 3, dy: 1.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)
        if isSelected {
            // A key window shows the full lavender fill; an inactive window keeps
            // the selection recognizable without competing for attention.
            let fill = window?.isKeyWindow == true ? Palette.selectionFill : Palette.selectionFillInactive
            fill.resolved(in: effectiveAppearance).setFill()
            path.fill()
        } else if hovered {
            Palette.rowHover.resolved(in: effectiveAppearance).setFill()
            path.fill()
        }
        super.draw(dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
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

/// A compact determinate progress track. It draws once per state change; there
/// is no continuous animation.
final class ProgressTrackView: NSView {
    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }
    var showsFill = true {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 56, height: 5) }

    override func draw(_ dirtyRect: NSRect) {
        let appearance = effectiveAppearance
        let bounds = self.bounds.insetBy(dx: 0, dy: (self.bounds.height - 5) / 2)
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        Palette.recessed.resolved(in: appearance).setFill()
        track.fill()
        guard showsFill, fraction > 0 else { return }
        var fillRect = bounds
        fillRect.size.width = max(bounds.height, bounds.width * CGFloat(min(max(fraction, 0), 1)))
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        Palette.accent.resolved(in: appearance).setFill()
        fill.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Reusable progress/status cell for the tree's Progress / Status column:
/// a compact track plus the readable percentage or explicit status text.
/// Every configure call resets all visual state, so reused cells cannot leak
/// a previous row's presentation.
final class TorrentProgressCellView: NSTableCellView {
    let track = ProgressTrackView()
    let statusText = NSTextField(labelWithString: "")
    private var trackWidth: NSLayoutConstraint!
    private var trackLeading: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        track.translatesAutoresizingMaskIntoConstraints = false
        statusText.translatesAutoresizingMaskIntoConstraints = false
        statusText.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusText.lineBreakMode = .byTruncatingTail
        addSubview(track)
        addSubview(statusText)
        // `textField` carries the status text so accessibility and help keep
        // working through the standard cell machinery.
        textField = statusText
        trackWidth = track.widthAnchor.constraint(equalToConstant: 56)
        trackLeading = track.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            trackLeading,
            trackWidth,
            track.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusText.leadingAnchor.constraint(equalTo: track.trailingAnchor, constant: 6),
            statusText.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            statusText.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Unsupported") }

    func configure(fraction: Double?, text: String, tint: NSColor) {
        track.showsFill = fraction != nil
        track.fraction = fraction ?? 0
        statusText.stringValue = text
        statusText.textColor = tint
    }

    /// Text-only statuses (for example "No files selected") drop the track and
    /// use the full cell width.
    func setTrackHidden(_ hidden: Bool) {
        trackWidth.constant = hidden ? 0 : 56
        trackLeading.constant = hidden ? 0 : 4
        track.isHidden = hidden
    }
}
