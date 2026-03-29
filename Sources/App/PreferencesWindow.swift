import AppKit
import HotKey

/// Minimal preferences panel for editing global keyboard shortcuts.
final class PreferencesWindow: NSPanel {

    private let hotkeyManager: HotkeyManager
    private var panelRecorder: ShortcutRecorderButton!
    private var carouselRecorder: ShortcutRecorderButton!

    init(hotkeyManager: HotkeyManager) {
        self.hotkeyManager = hotkeyManager
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Keyboard Shortcuts"
        isReleasedWhenClosed = false
        level = .floating
        setupUI()
    }

    func showWindow() {
        panelRecorder.keyCombo = hotkeyManager.panelCombo
        carouselRecorder.keyCombo = hotkeyManager.carouselCombo
        center()
        makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
    }

    // MARK: - UI Setup

    private func setupUI() {
        let contentView = NSView(frame: contentRect(forFrameRect: frame))
        self.contentView = contentView

        let padding: CGFloat = 20
        let rowHeight: CGFloat = 28
        let labelWidth: CGFloat = 140
        let buttonWidth: CGFloat = 160

        // Row 1: Panel shortcut
        let panelLabel = NSTextField(labelWithString: "Window Navigator:")
        panelLabel.frame = NSRect(x: padding, y: 100, width: labelWidth, height: rowHeight)
        panelLabel.alignment = .right
        contentView.addSubview(panelLabel)

        panelRecorder = ShortcutRecorderButton()
        panelRecorder.frame = NSRect(x: padding + labelWidth + 10, y: 100, width: buttonWidth, height: rowHeight)
        panelRecorder.keyCombo = hotkeyManager.panelCombo
        panelRecorder.onRecordingStarted = { [weak self] in self?.hotkeyManager.pauseAll() }
        panelRecorder.onRecorded = { [weak self] combo in
            self?.hotkeyManager.updatePanel(combo)
            self?.hotkeyManager.resumeAll()
        }
        panelRecorder.onRecordingCancelled = { [weak self] in self?.hotkeyManager.resumeAll() }
        contentView.addSubview(panelRecorder)

        // Row 2: Carousel shortcut
        let carouselLabel = NSTextField(labelWithString: "Window Carousel:")
        carouselLabel.frame = NSRect(x: padding, y: 64, width: labelWidth, height: rowHeight)
        carouselLabel.alignment = .right
        contentView.addSubview(carouselLabel)

        carouselRecorder = ShortcutRecorderButton()
        carouselRecorder.frame = NSRect(x: padding + labelWidth + 10, y: 64, width: buttonWidth, height: rowHeight)
        carouselRecorder.keyCombo = hotkeyManager.carouselCombo
        carouselRecorder.onRecordingStarted = { [weak self] in self?.hotkeyManager.pauseAll() }
        carouselRecorder.onRecorded = { [weak self] combo in
            self?.hotkeyManager.updateCarousel(combo)
            self?.hotkeyManager.resumeAll()
        }
        carouselRecorder.onRecordingCancelled = { [weak self] in self?.hotkeyManager.resumeAll() }
        contentView.addSubview(carouselRecorder)

        // Bottom buttons
        let resetButton = NSButton(title: "Reset Defaults", target: self, action: #selector(resetDefaults))
        resetButton.frame = NSRect(x: padding, y: 16, width: 120, height: 32)
        resetButton.bezelStyle = .rounded
        contentView.addSubview(resetButton)

        let doneButton = NSButton(title: "Done", target: self, action: #selector(doneAction))
        doneButton.frame = NSRect(x: 280, y: 16, width: 80, height: 32)
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        contentView.addSubview(doneButton)
    }

    @objc private func resetDefaults() {
        hotkeyManager.resetDefaults()
        panelRecorder.keyCombo = hotkeyManager.panelCombo
        carouselRecorder.keyCombo = hotkeyManager.carouselCombo
    }

    @objc private func doneAction() {
        orderOut(nil)
    }
}

// MARK: - ShortcutRecorderButton

/// A button that captures the next key-down event as a shortcut.
/// Click to start recording, press a modifier+key combo to set, Escape to cancel.
private class ShortcutRecorderButton: NSButton {

    var keyCombo: KeyCombo? {
        didSet { updateDisplay() }
    }
    var onRecordingStarted: (() -> Void)?
    var onRecorded: ((KeyCombo) -> Void)?
    var onRecordingCancelled: (() -> Void)?

    private var isRecording = false
    private var eventMonitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        updateDisplay()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { stopRecording() }

    // MARK: - Display

    private func updateDisplay() {
        title = isRecording ? "Type shortcut…" : (keyCombo?.description ?? "None")
    }

    // MARK: - Recording

    @objc private func toggleRecording() {
        if isRecording {
            stopRecording()
            updateDisplay()
            onRecordingCancelled?()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        updateDisplay()
        onRecordingStarted?()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event)
            return nil // consume the event
        }
    }

    private func handleKey(_ event: NSEvent) {
        stopRecording()

        // Escape cancels
        if event.keyCode == 53 {
            updateDisplay()
            onRecordingCancelled?()
            return
        }

        // Require at least one real modifier (ignore caps lock, numpad, fn)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard !mods.isEmpty else {
            updateDisplay()
            onRecordingCancelled?()
            return
        }

        let combo = KeyCombo(carbonKeyCode: UInt32(event.keyCode), carbonModifiers: mods.carbonFlags)
        keyCombo = combo
        onRecorded?(combo)
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
