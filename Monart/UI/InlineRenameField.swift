import AppKit
import SwiftUI

/// An AppKit text field for renaming in place inside a List row.
///
/// SwiftUI's `@FocusState` is unreliable for text fields inside a macOS `List` (the
/// table takes focus back, and after the first edit the field often never gets focus
/// again). This field makes itself first responder as soon as it's in a window and
/// reports exactly one outcome: commit (Return or clicking elsewhere) or cancel (Esc).
struct InlineRenameField: NSViewRepresentable {
    let initialText: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> AutoFocusTextField {
        let field = AutoFocusTextField(string: initialText)
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: AutoFocusTextField, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineRenameField
        private var finished = false

        init(parent: InlineRenameField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                finish(control, commit: true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish(control, commit: false)
                return true
            default:
                return false
            }
        }

        /// Focus moved elsewhere (clicked another row, the canvas, ...): keep the edit.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            finish(field, commit: true)
        }

        private func finish(_ control: NSControl, commit: Bool) {
            guard !finished else { return }
            finished = true
            let text = control.stringValue
            // Release the field editor first; the resulting end-editing callback is ignored.
            if control.window?.firstResponder === (control as? NSTextField)?.currentEditor() {
                control.window?.makeFirstResponder(nil)
            }
            commit ? parent.onCommit(text) : parent.onCancel()
        }
    }
}

final class AutoFocusTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Next turn, after the table has finished handling the double-click.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
            self.currentEditor()?.selectAll(nil)
        }
    }
}
