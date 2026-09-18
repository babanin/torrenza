import AppKit
import SwiftUI

/// A content-sized native search field keeps the toolbar's right-hand ordering
/// stable, including the inspector at the outer edge. Search remains live.
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focusRequest: focusRequest) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search torrents and files"
        field.controlSize = .large
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
        CGSize(width: proposal.width ?? 240, height: 28)
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
