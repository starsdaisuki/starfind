import SwiftUI
import AppKit

/// 搜索输入框。
///
/// 用 NSViewRepresentable 包 NSTextField 而不是直接用 SwiftUI 的 TextField ——
/// 启动器对「面板一出来光标就在框里」的可靠性要求很高，
/// 自己调 `window.makeFirstResponder(field)` 比指望 @FocusState 稳。
struct QueryField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// 这个值一变就重新抢焦点（面板每次显示时 +1）
    var focusToken: Int

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusableTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .light)
        field.textColor = .labelColor
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .light),
                         .foregroundColor: NSColor.tertiaryLabelColor]
        )
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        // 输入法候选框要靠这个才会跟着光标走
        field.allowsEditingTextAttributes = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                // 光标挪到末尾，别选中全部（重新唤起时保留上次的词方便接着改）
                if let editor = field.currentEditor() {
                    editor.selectedRange = NSRange(location: field.stringValue.count, length: 0)
                }
            }
        }

        if let ph = field.placeholderAttributedString?.string, ph != placeholder {
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .light),
                             .foregroundColor: NSColor.tertiaryLabelColor]
            )
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QueryField
        var lastFocusToken = -1
        init(_ parent: QueryField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}

/// 无边框窗口里的 NSTextField 默认不肯当 first responder，覆一下
private final class FocusableTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
}
