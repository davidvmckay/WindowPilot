import AppKit
import HotKey

/// Registers and manages the global Option+Space hotkey.
/// The caller provides an `onToggle` closure that is invoked on every key-down
/// event — it is responsible for showing or hiding the panel.
///
/// The `HotKey` object MUST be kept alive for as long as the hotkey should
/// remain active.  Storing it as a `var` property on this class satisfies
/// that requirement.
final class HotkeyManager {
    private var hotKey: HotKey?
    private let onToggle: () -> Void

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        setupHotkey()
    }

    private func setupHotkey() {
        hotKey = HotKey(key: .space, modifiers: [.option])
        hotKey?.keyDownHandler = { [weak self] in
            self?.onToggle()
        }
    }
}
