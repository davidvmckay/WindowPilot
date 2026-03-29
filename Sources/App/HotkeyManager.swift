import AppKit
import HotKey

/// Registers and manages global hotkeys with UserDefaults persistence.
/// - Default Option+Space: toggle the main panel
/// - Default Ctrl+Option+Space: show the carousel
final class HotkeyManager {

    static let defaultPanelCombo = KeyCombo(key: .space, modifiers: [.option])
    static let defaultCarouselCombo = KeyCombo(key: .space, modifiers: [.control, .option])

    private var panelHotKey: HotKey?
    private var carouselHotKey: HotKey?

    private(set) var panelCombo: KeyCombo
    private(set) var carouselCombo: KeyCombo

    private let onToggle: () -> Void
    private let onCarousel: () -> Void

    /// Called after any shortcut change so the menu can update its labels.
    var onShortcutsChanged: (() -> Void)?

    init(onToggle: @escaping () -> Void, onCarousel: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onCarousel = onCarousel
        self.panelCombo = Self.load(key: "panelShortcut") ?? Self.defaultPanelCombo
        self.carouselCombo = Self.load(key: "carouselShortcut") ?? Self.defaultCarouselCombo
        register()
    }

    // MARK: - Display

    var panelShortcutDisplay: String { panelCombo.description }
    var carouselShortcutDisplay: String { carouselCombo.description }

    // MARK: - Update

    func updatePanel(_ combo: KeyCombo) {
        panelCombo = combo
        Self.save(combo, key: "panelShortcut")
        register()
        onShortcutsChanged?()
    }

    func updateCarousel(_ combo: KeyCombo) {
        carouselCombo = combo
        Self.save(combo, key: "carouselShortcut")
        register()
        onShortcutsChanged?()
    }

    func resetDefaults() {
        panelCombo = Self.defaultPanelCombo
        carouselCombo = Self.defaultCarouselCombo
        UserDefaults.standard.removeObject(forKey: "panelShortcut")
        UserDefaults.standard.removeObject(forKey: "carouselShortcut")
        register()
        onShortcutsChanged?()
    }

    // MARK: - Pause / Resume (used during shortcut recording)

    func pauseAll() {
        panelHotKey?.isPaused = true
        carouselHotKey?.isPaused = true
    }

    func resumeAll() {
        panelHotKey?.isPaused = false
        carouselHotKey?.isPaused = false
    }

    // MARK: - Private

    private func register() {
        panelHotKey = nil
        carouselHotKey = nil

        panelHotKey = HotKey(keyCombo: panelCombo)
        panelHotKey?.keyDownHandler = { [weak self] in self?.onToggle() }

        carouselHotKey = HotKey(keyCombo: carouselCombo)
        carouselHotKey?.keyDownHandler = { [weak self] in self?.onCarousel() }
    }

    private static func save(_ combo: KeyCombo, key: String) {
        UserDefaults.standard.set(combo.dictionary, forKey: key)
    }

    private static func load(key: String) -> KeyCombo? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key) else { return nil }
        return KeyCombo(dictionary: dict)
    }
}
