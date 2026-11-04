import AppKit
import SwiftUI

/// One semantic palette shared by SwiftUI and AppKit. Every color resolves
/// through the current appearance and accessibility settings, so the same
/// token can back a SwiftUI background and an AppKit row fill.
enum Palette {
    /// Warm cream workspace canvas (light) over warm charcoal (dark).
    static let canvas = dynamic(light: 0xF7F3EC, dark: 0x211F24)
    /// Near-white panel surface (light) over raised charcoal (dark).
    static let panel = dynamic(light: 0xFFFDFA, dark: 0x2B2830)
    /// Quiet inset surface for wells, shelves, and grouped rows.
    static let recessed = dynamic(light: 0xF1EDE6, dark: 0x242128)
    /// One-physical-pixel panel border; stronger when Increase Contrast is on.
    static let border = dynamic(light: 0xDED9D2, dark: 0x49434F, highContrastLight: 0xC8C1B7, highContrastDark: 0x5C5468)
    /// Pale lavender selection fill; the workspace's navigation color.
    static let selectionFill = dynamic(light: 0xE3DCF8, dark: 0x514367)
    /// Foreground that stays readable on the selection fill.
    static let selectionText = dynamic(light: 0x3A2E55, dark: 0xEDE7F8)
    /// Deep violet accent (light) and light violet accent (dark).
    static let accent = dynamic(light: 0x65508C, dark: 0xC5AFE8)
    /// Restrained amber for primary entry actions.
    static let primaryAction = dynamic(light: 0xF3DB9B, dark: 0x68532D)
    /// Foreground that stays readable on the primary-action fill.
    static let primaryActionText = dynamic(light: 0x4A3A12, dark: 0xF7E7C4)
    /// Quiet row hover on the panel surface.
    static let rowHover = dynamicOverlay(alpha: 0.045, base: (light: 0x65508C, dark: 0xC5AFE8))
    /// Muted selection for an inactive window.
    static let selectionFillInactive = dynamicOverlay(alpha: 0.38, base: selectionFillLightDark)

    private static let selectionFillLightDark: (light: UInt32, dark: UInt32) = (light: 0xC9BCF1, dark: 0x6E5C8C)

    private static func dynamic(light: UInt32, dark: UInt32, highContrastLight: UInt32? = nil, highContrastDark: UInt32? = nil) -> NSColor {
        NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
               let highContrastLight, let highContrastDark {
                return NSColor(hex: isDark ? highContrastDark : highContrastLight)
            }
            return NSColor(hex: isDark ? dark : light)
        })
    }

    /// A translucent overlay that keeps its hue in both appearances.
    private static func dynamicOverlay(alpha: CGFloat, base: (light: UInt32, dark: UInt32)) -> NSColor {
        NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? base.dark : base.light).withAlphaComponent(alpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }

    /// Dynamic palette colors must be resolved before use as a layer or fill
    /// color that is not redrawn on appearance changes.
    func resolved(in appearance: NSAppearance) -> NSColor {
        var result = self
        appearance.performAsCurrentDrawingAppearance {
            result = usingColorSpace(.sRGB) ?? self
        }
        return result
    }

    var resolved: NSColor {
        resolved(in: NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!)
    }
}

extension Color {
    static let torrenzaCanvas = Color(nsColor: Palette.canvas)
    static let torrenzaPanel = Color(nsColor: Palette.panel)
    static let torrenzaRecessed = Color(nsColor: Palette.recessed)
    static let torrenzaBorder = Color(nsColor: Palette.border)
    static let torrenzaSelection = Color(nsColor: Palette.selectionFill)
    static let torrenzaSelectionText = Color(nsColor: Palette.selectionText)
    static let torrenzaAccent = Color(nsColor: Palette.accent)
    static let torrenzaPrimaryAction = Color(nsColor: Palette.primaryAction)
    static let torrenzaPrimaryActionText = Color(nsColor: Palette.primaryActionText)
}

/// Shared workspace geometry. Values are points.
enum WorkspaceMetrics {
    /// Spacing scale: 4, 8, 12, 16, 24.
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space6: CGFloat = 24
    static let outerPadding: CGFloat = 12
    static let panelSpacing: CGFloat = 12
    static let panelRadius: CGFloat = 14
    static let groupRadius: CGFloat = 8
    static let hairline: CGFloat = 0.5
    /// Main content text.
    static let contentFontSize: CGFloat = 13
    /// Secondary metadata.
    static let metadataFontSize: CGFloat = 12
    static let sidebarMinWidth: CGFloat = 184
    static let sidebarIdealWidth: CGFloat = 208
    static let sidebarMaxWidth: CGFloat = 260
    static let inspectorMinWidth: CGFloat = 280
    static let inspectorIdealWidth: CGFloat = 304
    static let inspectorMaxWidth: CGFloat = 420
    static let centralMinWidth: CGFloat = 420
    static let sidebarRowHeight: CGFloat = 32
    static let treeRowHeight: CGFloat = 30
    static let shelfHeight: CGFloat = 44
    static let searchFieldWidth: CGFloat = 240

    static func clamp(_ width: Double, min minimum: Double, max maximum: Double) -> Double {
        guard width.isFinite else { return minimum }
        return Swift.min(Swift.max(width, minimum), maximum)
    }
}

/// A rounded workspace panel with a hairline border. Clipping stays outside
/// any scroll view so scrollers and focus rings remain usable.
struct PanelContainer<Content: View>: View {
    var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .background(Color.torrenzaPanel, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius, style: .continuous)
                    .strokeBorder(Color.torrenzaBorder, lineWidth: WorkspaceMetrics.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius, style: .continuous))
    }
}

/// A quiet inset group used inside panels and sheets.
struct GroupSurface<Content: View>: View {
    var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .background(Color.torrenzaRecessed, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.groupRadius, style: .continuous))
    }
}

/// Shared sheet header: title, optional subtitle, optional symbol.
struct SheetHeader: View {
    let title: String
    var subtitle: String?
    var systemImage: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.space2) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: WorkspaceMetrics.contentFontSize, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: WorkspaceMetrics.space1) {
                Text(title).font(.system(size: 17, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: WorkspaceMetrics.metadataFontSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Shared sheet footer: flexible leading content and trailing actions.
struct SheetFooter<Leading: View, Actions: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: WorkspaceMetrics.space3) {
            leading()
            Spacer(minLength: WorkspaceMetrics.space2)
            actions()
        }
    }
}

/// Inline notice with a symbol and readable explanation.
struct NoticeView: View {
    enum Kind {
        case error
        case warning
        case info

        var symbol: String {
            switch self {
            case .error: "xmark.octagon"
            case .warning: "exclamationmark.triangle"
            case .info: "info.circle"
            }
        }

        var color: Color {
            switch self {
            case .error: .red
            case .warning: .orange
            case .info: .secondary
            }
        }
    }

    let kind: Kind
    let title: String
    var message: String?

    var body: some View {
        HStack(alignment: .top, spacing: WorkspaceMetrics.space2) {
            Image(systemName: kind.symbol)
                .font(.system(size: WorkspaceMetrics.contentFontSize, weight: .semibold))
                .foregroundStyle(kind.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WorkspaceMetrics.space1) {
                Text(title).font(.system(size: WorkspaceMetrics.contentFontSize, weight: .semibold))
                if let message {
                    Text(message)
                        .font(.system(size: WorkspaceMetrics.metadataFontSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(WorkspaceMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GroupSurface { Color.torrenzaRecessed })
        .accessibilityElement(children: .combine)
    }
}
