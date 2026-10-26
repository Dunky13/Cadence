import AppKit
import SwiftUI

/// Shell input must preserve punctuation and whitespace instead of applying
/// macOS's prose-oriented smart quotes, dashes, replacements, or spelling fixes.
struct CommandEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> CommandScrollView {
        let scroll = CommandScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = scroll.editor
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width: 3, height: 5)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.string = text
        editor.setAccessibilityLabel("Command")
        editor.setAccessibilityIdentifier("new-job-command")
        context.coordinator.editor = editor
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: CommandScrollView, context: Context) {
        context.coordinator.binding = $text
        if scroll.editor.string != text { scroll.editor.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(binding: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var binding: Binding<String>
        weak var editor: NSTextView?

        init(binding: Binding<String>) { self.binding = binding }
        func textDidChange(_ notification: Notification) {
            guard let editor else { return }
            binding.wrappedValue = editor.string
        }
    }
}

final class CommandScrollView: NSScrollView {
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 73))
}
