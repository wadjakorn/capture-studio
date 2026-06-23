import SwiftUI
import AppKit

/// Multiline caption editor with key semantics: plain Return submits (applies),
/// Esc submits, and Shift+Return inserts a newline. Live text changes flow
/// through the binding so the canvas preview updates as you type. Wraps
/// `NSTextView` via `NSViewRepresentable` — the CLT-safe pattern for AppKit
/// views (SwiftUI's own multiline TextField can't split Return vs Shift+Return).
struct CaptionTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Editable only while a text block is selected; otherwise read-only/greyed.
    var isEnabled: Bool = true
    /// Selected block id — when it changes (block switch / add), grab focus and
    /// move the caret to the end. Stable across keystrokes, so typing never
    /// fights for focus.
    var focusToken: UUID? = nil
    var onSubmit: () -> Void
    /// Esc handler. Defaults to `onSubmit`; pass a closure to deselect instead.
    var onCancel: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.font = .systemFont(ofSize: 13)
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.allowsUndo = true
        tv.string = text
        tv.isEditable = isEnabled
        tv.isSelectable = isEnabled
        tv.textColor = isEnabled ? .labelColor : .secondaryLabelColor
        tv.textContainerInset = NSSize(width: 4, height: 6)
        scroll.drawsBackground = false
        context.coordinator.lastToken = focusToken
        // Focus once the view is in a window — only when actually editable.
        if isEnabled { focus(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        if tv.isEditable != isEnabled {
            tv.isEditable = isEnabled
            tv.isSelectable = isEnabled
            tv.textColor = isEnabled ? .labelColor : .secondaryLabelColor
            if !isEnabled, tv.window?.firstResponder === tv {
                tv.window?.makeFirstResponder(nil)
            }
        }
        // Refocus on a block switch/add (token change) — never on a keystroke.
        if isEnabled, context.coordinator.lastToken != focusToken {
            focus(tv)
        }
        context.coordinator.lastToken = focusToken
    }

    private func focus(_ tv: NSTextView) {
        DispatchQueue.main.async { [weak tv] in
            guard let tv else { return }
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: tv.string.count, length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: CaptionTextEditor
        var lastToken: UUID?
        init(_ parent: CaptionTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift+Return → literal newline; plain Return → apply.
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    tv.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // Esc deselects the block (which commits) when a handler is set,
                // else falls back to a plain submit.
                if let onCancel = parent.onCancel { onCancel() } else { parent.onSubmit() }
                return true
            default:
                return false
            }
        }
    }
}
