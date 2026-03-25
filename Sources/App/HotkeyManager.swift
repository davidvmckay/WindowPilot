import AppKit
import HotKey

/// Registers and manages global hotkeys.
/// - Option+Space: toggle the main panel
/// - Ctrl+Option+Space: show the carousel (hold-to-browse)
final class HotkeyManager {
    private var panelHotKey: HotKey?
    private var carouselHotKey: HotKey?

    private let onToggle: () -> Void
    private let onCarousel: () -> Void

    init(onToggle: @escaping () -> Void, onCarousel: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onCarousel = onCarousel
        setupHotkeys()
    }

    private func setupHotkeys() {
        // Option+Space → toggle panel
        panelHotKey = HotKey(key: .space, modifiers: [.option])
        panelHotKey?.keyDownHandler = { [weak self] in
            self?.onToggle()
        }

        // Ctrl+Option+Space → show carousel
        carouselHotKey = HotKey(key: .space, modifiers: [.control, .option])
        carouselHotKey?.keyDownHandler = { [weak self] in
            self?.onCarousel()
        }
    }
}
