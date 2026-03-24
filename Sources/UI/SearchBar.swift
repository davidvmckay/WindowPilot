import AppKit

// MARK: - SearchBar

/// A search bar view hosting an NSTextField with 30ms debounced change callbacks.
/// Handles Escape and Tab key events for panel-level navigation.
public final class SearchBar: NSView {

    // MARK: Subviews

    private let textField = InternalTextField()

    // MARK: State

    private var debounceWorkItem: DispatchWorkItem?

    // MARK: Callbacks

    /// Called after a 30ms debounce whenever the search text changes.
    public var onTextChanged: ((String) -> Void)?

    /// Called when the user presses Escape while the search field is empty.
    public var onEscapeWhenEmpty: (() -> Void)?

    // MARK: Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildLayout()
    }

    // MARK: Public API

    /// Makes the embedded text field first responder and selects all existing text.
    public func focusSearchField() {
        window?.makeFirstResponder(textField)
        textField.selectText(nil)
    }

    // MARK: Private helpers

    private func buildLayout() {
        // Configure the text field
        textField.placeholderString = "Filter windows… ⌘K"
        textField.bezelStyle = .roundedBezel
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        textField.textColor = NSColor.labelColor
        textField.delegate = textField

        // Wire the internal escape/tab callbacks to our public surface
        textField.onEscapePressed = { [weak self] in
            guard let self else { return }
            let text = self.textField.stringValue
            if text.isEmpty {
                self.onEscapeWhenEmpty?()
            } else {
                self.textField.stringValue = ""
                self.fireDebounced(text: "")
            }
        }

        textField.onTabPressed = { [weak self] in
            guard let self, let window = self.window else { return }
            window.selectNextKeyView(nil)
        }

        textField.onTextChanged = { [weak self] text in
            self?.fireDebounced(text: text)
        }

        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)

        // Separator line at bottom of the search bar
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            // Text field: centered vertically, full width with horizontal inset
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Separator: pinned to the bottom edge
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Cancel any pending debounce, schedule a new one that fires after 30ms.
    private func fireDebounced(text: String) {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.onTextChanged?(text)
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: item)
    }
}

// MARK: - InternalTextField

/// NSTextField subclass that intercepts Escape and Tab via the command-selector
/// delegate method, forwarding them to closures so SearchBar can respond.
private final class InternalTextField: NSTextField, NSTextFieldDelegate {

    var onEscapePressed: (() -> Void)?
    var onTabPressed: (() -> Void)?
    var onTextChanged: ((String) -> Void)?

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        onTextChanged?(stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(cancelOperation(_:)):
            // Escape key
            onEscapePressed?()
            return true
        case #selector(insertTab(_:)):
            // Tab key
            onTabPressed?()
            return true
        default:
            return false
        }
    }
}
