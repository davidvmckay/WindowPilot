import AppKit
import WindowPilotCore

// MARK: - CarouselPanel

/// Horizontal window carousel for hold-to-browse switching.
/// Ctrl+Option+Space shows it, arrow keys navigate, releasing modifiers activates.
public final class CarouselPanel: NSPanel {

    // MARK: Callbacks

    /// Called when the user releases modifiers (activates the selected window).
    public var onWindowActivated: ((WindowInfo) -> Void)?

    /// Called when dismissed without selecting (Esc).
    public var onDismissed: (() -> Void)?

    // MARK: State

    private var windows: [CarouselItem] = []
    private var selectedIndex: Int = 0
    private var cardViews: [WindowCardView] = []
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?

    // MARK: Subviews

    private let scrollView = NSScrollView()
    private let containerView = NSView()
    private let visualEffect = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")

    // MARK: Init

    public init() {
        let rect = NSRect(x: 0, y: 0, width: 700, height: 180)
        super.init(
            contentRect: rect,
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel()
        buildLayout()
    }

    public override var canBecomeKey: Bool { true }

    // MARK: Public API

    /// Show the carousel with a list of windows. Pre-selects index 1
    /// (the previous window, since index 0 is the current window).
    public func show(items: [CarouselItem]) {
        self.windows = items
        selectedIndex = items.count > 1 ? 1 : 0
        rebuildCards()
        centerOnCursorScreen()
        makeKeyAndOrderFront(nil)
        startModifierMonitor()
    }

    /// Dismiss without activating.
    public func dismiss() {
        stopModifierMonitor()
        orderOut(nil)
    }

    /// Update thumbnails after a background refresh (windowID → image).
    public func updateThumbnails(_ thumbnails: [UInt32: CGImage]) {
        for (i, item) in windows.enumerated() {
            guard let img = thumbnails[item.windowID], i < cardViews.count else { continue }
            windows[i] = CarouselItem(
                windowID: item.windowID, pid: item.pid,
                appName: item.appName, windowTitle: item.windowTitle,
                thumbnail: img
            )
            cardViews[i].updateThumbnail(img)
        }
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 124: // Right arrow
            selectCard(at: min(selectedIndex + 1, windows.count - 1))
        case 123: // Left arrow
            selectCard(at: max(selectedIndex - 1, 0))
        case 53: // Esc
            dismiss()
            onDismissed?()
        default:
            break
        }
    }

    // MARK: Private — Config

    private func configurePanel() {
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false

        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.cornerCurve = .continuous
        visualEffect.layer?.masksToBounds = true
        contentView = visualEffect
    }

    // MARK: Private — Layout

    private func buildLayout() {
        guard let contentView else { return }

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(titleLabel)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        contentView.addSubview(scrollView)

        containerView.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.drawsBackground = false
        clipView.documentView = containerView
        scrollView.contentView = clipView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -6),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            titleLabel.heightAnchor.constraint(equalToConstant: 18),

            containerView.topAnchor.constraint(equalTo: clipView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            containerView.heightAnchor.constraint(equalTo: clipView.heightAnchor),
        ])
    }

    // MARK: Private — Cards

    private func rebuildCards() {
        for card in cardViews {
            card.removeFromSuperview()
        }
        cardViews.removeAll()

        let cardWidth: CGFloat = 140
        let cardHeight: CGFloat = 120
        let spacing: CGFloat = 8

        for (index, item) in windows.enumerated() {
            let card = WindowCardView(appName: item.appName, pid: item.pid, thumbnail: item.thumbnail)
            card.frame = NSRect(
                x: CGFloat(index) * (cardWidth + spacing),
                y: 0,
                width: cardWidth,
                height: cardHeight
            )
            containerView.addSubview(card)
            cardViews.append(card)
        }

        containerView.frame.size = NSSize(
            width: CGFloat(windows.count) * (cardWidth + spacing) - spacing,
            height: cardHeight
        )

        updateSelection()
    }

    private func selectCard(at index: Int) {
        guard index >= 0, index < windows.count else { return }
        selectedIndex = index
        updateSelection()
    }

    private func updateSelection() {
        for (i, card) in cardViews.enumerated() {
            card.setSelected(i == selectedIndex)
        }

        // Scroll to selected card
        if selectedIndex < cardViews.count {
            let cardFrame = cardViews[selectedIndex].frame
            scrollView.contentView.scrollToVisible(cardFrame)
        }

        // Update title
        if selectedIndex < windows.count {
            let item = windows[selectedIndex]
            titleLabel.stringValue = "\(item.appName) — \(item.windowTitle)"
        }
    }

    // MARK: Private — Modifier Monitor

    private func startModifierMonitor() {
        stopModifierMonitor()

        let required: NSEvent.ModifierFlags = [.control, .option]

        // Global monitor — catches events when other apps are active
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.isVisible else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(required) {
                self.activateSelected()
            }
        }

        // Local monitor — catches events when our panel is key
        // (nonactivatingPanel can still receive some events locally)
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.isVisible else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(required) {
                self.activateSelected()
            }
            return event
        }
    }

    private func stopModifierMonitor() {
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
        if let monitor = localFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            localFlagsMonitor = nil
        }
    }

    private func activateSelected() {
        guard selectedIndex >= 0, selectedIndex < windows.count else {
            dismiss()
            return
        }
        let item = windows[selectedIndex]
        let windowInfo = WindowInfo(
            id: item.windowID,
            ownerPID: item.pid,
            title: item.windowTitle,
            bounds: .zero,
            state: .normal  // performFocus re-detects via CGS
        )
        dismiss()
        onWindowActivated?(windowInfo)
    }

    // MARK: Private — Positioning

    private func centerOnCursorScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens[0]

        let screenFrame = screen.visibleFrame
        let panelSize = frame.size
        let origin = NSPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.midY - panelSize.height / 2
        )
        setFrameOrigin(origin)
    }
}

// MARK: - CarouselItem

/// Data for one item in the carousel.
public struct CarouselItem {
    public let windowID: UInt32
    public let pid: Int32
    public let appName: String
    public let windowTitle: String
    public let thumbnail: CGImage?

    public init(windowID: UInt32, pid: Int32, appName: String, windowTitle: String, thumbnail: CGImage?) {
        self.windowID = windowID
        self.pid = pid
        self.appName = appName
        self.windowTitle = windowTitle
        self.thumbnail = thumbnail
    }
}
