import AppKit
import WindowPilotCore

// MARK: - RecentView

/// Grid of most recently used windows with thumbnail previews.
/// 3 columns per row. Each card: screenshot on top, info below.
public final class RecentView: NSView {

    // MARK: Callbacks

    public var onWindowSelected: ((WindowInfo) -> Void)?
    public var onWindowActivated: ((WindowInfo) -> Void)?

    // MARK: Constants

    private let columns = 3
    private let cardSpacing: CGFloat = 8
    private let cardPadding: CGFloat = 10

    // MARK: Subviews

    private let scrollView = NSScrollView()
    private let containerView = FlippedView()

    // MARK: State

    private var trackedWindows: [TrackedWindow] = []
    private var thumbnails: [UInt32: CGImage] = [:]
    private var cardViews: [RecentCardView] = []
    private var selectedIndex: Int = -1

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

    /// The WindowInfo for the currently selected card, or nil when no card is
    /// selected. Single source of truth for the Recent tab's active window.
    public var selectedWindowInfo: WindowInfo? {
        guard selectedIndex >= 0, selectedIndex < trackedWindows.count else { return nil }
        return windowInfo(from: trackedWindows[selectedIndex])
    }

    public func reloadData(windows: [TrackedWindow], thumbnails: [UInt32: CGImage]) {
        self.trackedWindows = windows
        self.thumbnails = thumbnails
        selectedIndex = -1
        rebuildGrid()
    }

    public func updateThumbnails(_ newThumbnails: [UInt32: CGImage]) {
        for (wid, image) in newThumbnails {
            thumbnails[wid] = image
        }
        for (i, card) in cardViews.enumerated() {
            guard i < trackedWindows.count,
                  let img = newThumbnails[trackedWindows[i].id] else { continue }
            card.updateThumbnail(img)
        }
    }

    /// Select the initial card for keyboard navigation. Index 0 is the window
    /// that was focused when the panel opened, so preselect index 1 (the
    /// "previous" window) when available — same logic as CarouselPanel.
    public func selectInitialCard() {
        guard !trackedWindows.isEmpty else { return }
        selectCard(at: trackedWindows.count > 1 ? 1 : 0)
    }

    // MARK: Keyboard

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 124: // Right arrow
            selectCard(at: min(selectedIndex + 1, trackedWindows.count - 1))
        case 123: // Left arrow
            selectCard(at: max(selectedIndex - 1, 0))
        case 125: // Down arrow
            selectCard(at: min(selectedIndex + columns, trackedWindows.count - 1))
        case 126: // Up arrow
            selectCard(at: max(selectedIndex - columns, 0))
        case 36: // Enter
            if selectedIndex >= 0, selectedIndex < trackedWindows.count {
                onWindowActivated?(windowInfo(from: trackedWindows[selectedIndex]))
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        layoutCards()
    }

    // MARK: Private

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        containerView.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.drawsBackground = false
        clipView.documentView = containerView
        scrollView.contentView = clipView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            containerView.topAnchor.constraint(equalTo: clipView.topAnchor),
            containerView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            containerView.widthAnchor.constraint(equalTo: clipView.widthAnchor),
        ])
    }

    private func rebuildGrid() {
        // Remove old cards
        for card in cardViews {
            card.removeFromSuperview()
        }
        cardViews.removeAll()

        if trackedWindows.isEmpty {
            let label = NSTextField(labelWithString: "No recent windows yet")
            label.textColor = .tertiaryLabelColor
            label.alignment = .center
            label.font = .systemFont(ofSize: 13)
            label.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
                label.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 40),
            ])
            containerView.frame.size.height = 100
            return
        }

        for (index, tracked) in trackedWindows.enumerated() {
            let card = RecentCardView(
                tracked: tracked,
                thumbnail: thumbnails[tracked.id],
                index: index
            )
            // Single click = activate (switch to that window)
            card.onClicked = { [weak self] idx in
                guard let self, idx < self.trackedWindows.count else { return }
                self.selectCard(at: idx)
                self.onWindowActivated?(self.windowInfo(from: self.trackedWindows[idx]))
            }
            card.onDoubleClicked = { [weak self] idx in
                guard let self, idx < self.trackedWindows.count else { return }
                self.onWindowActivated?(self.windowInfo(from: self.trackedWindows[idx]))
            }
            containerView.addSubview(card)
            cardViews.append(card)
        }

        layoutCards()
    }

    private func layoutCards() {
        let totalWidth = scrollView.contentView.bounds.width
        guard totalWidth > 0, !cardViews.isEmpty else { return }

        let availableWidth = totalWidth - cardPadding * 2 - cardSpacing * CGFloat(columns - 1)
        let cardWidth = max(availableWidth / CGFloat(columns), 100)
        let thumbHeight = cardWidth * 0.6  // 5:3 aspect ratio
        let cardHeight = thumbHeight + 52  // thumbnail + info area

        // Flipped view: y=0 is top-left, increases downward
        for (index, card) in cardViews.enumerated() {
            let col = index % columns
            let row = index / columns
            let x = cardPadding + CGFloat(col) * (cardWidth + cardSpacing)
            let y = cardPadding + CGFloat(row) * (cardHeight + cardSpacing)

            card.frame = NSRect(x: x, y: y, width: cardWidth, height: cardHeight)
            card.updateLayout(thumbnailHeight: thumbHeight)
        }

        let totalRows = (cardViews.count + columns - 1) / columns
        containerView.frame.size.height = cardPadding * 2 + CGFloat(totalRows) * (cardHeight + cardSpacing) - cardSpacing
    }

    private func selectCard(at index: Int) {
        guard index >= 0, index < trackedWindows.count else { return }

        if selectedIndex >= 0, selectedIndex < cardViews.count {
            cardViews[selectedIndex].setSelected(false)
        }
        selectedIndex = index
        if index < cardViews.count {
            cardViews[index].setSelected(true)
        }

        onWindowSelected?(windowInfo(from: trackedWindows[index]))
    }

    private func windowInfo(from tracked: TrackedWindow) -> WindowInfo {
        WindowInfo(
            id: tracked.id,
            ownerPID: tracked.pid,
            title: tracked.windowTitle,
            bounds: .zero,
            state: tracked.isFullScreen ? .fullScreen : .normal
        )
    }
}

// MARK: - RecentCardView

/// A single card in the grid. Screenshot on top, info below.
final class RecentCardView: NSView {

    var onClicked: ((Int) -> Void)?
    var onDoubleClicked: ((Int) -> Void)?

    private let index: Int
    private var selected = false
    private let thumbnailView: WindowThumbnailView
    private let infoStack = NSStackView()
    private let appLine = NSStackView()
    private let appIconView = NSImageView()
    private let appNameLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")

    init(tracked: TrackedWindow, thumbnail: CGImage?, index: Int) {
        self.index = index
        self.thumbnailView = WindowThumbnailView(
            thumbnail: thumbnail,
            cornerRadius: 8,
            maskedCorners: [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor

        addSubview(thumbnailView)

        // App icon + name line
        appIconView.imageScaling = .scaleProportionallyDown
        if let app = NSRunningApplication(processIdentifier: tracked.pid) {
            appIconView.image = app.icon
        }

        appNameLabel.stringValue = tracked.appName
        appNameLabel.textColor = .secondaryLabelColor
        appNameLabel.font = .systemFont(ofSize: 10)
        appNameLabel.lineBreakMode = .byTruncatingTail
        appNameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Window title
        titleLabel.stringValue = tracked.windowTitle
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail

        // Meta
        metaLabel.stringValue = "\(tracked.durationText)  ·  \(tracked.agoText)"
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.font = .systemFont(ofSize: 10)

        addSubview(appIconView)
        addSubview(appNameLabel)
        addSubview(titleLabel)
        addSubview(metaLabel)

        // Gestures
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
        click.delaysPrimaryMouseButtonEvents = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func updateLayout(thumbnailHeight: CGFloat) {
        let w = bounds.width
        let pad: CGFloat = 6

        // Flipped: y=0 is top. Thumbnail at top, info below.
        thumbnailView.frame = NSRect(x: 0, y: 0, width: w, height: thumbnailHeight)

        let infoTop = thumbnailHeight + 4
        appIconView.frame = NSRect(x: pad, y: infoTop, width: 12, height: 12)
        appNameLabel.frame = NSRect(x: pad + 15, y: infoTop - 1, width: w - pad * 2 - 15, height: 14)
        titleLabel.frame = NSRect(x: pad, y: infoTop + 14, width: w - pad * 2, height: 15)
        metaLabel.frame = NSRect(x: pad, y: infoTop + 29, width: w - pad * 2, height: 14)
    }

    func setSelected(_ selected: Bool) {
        self.selected = selected
        layer?.borderColor = selected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        layer?.borderWidth = selected ? 2 : 1
    }

    func updateThumbnail(_ image: CGImage) {
        thumbnailView.setThumbnail(image)
    }

    @objc private func handleClick() { onClicked?(index) }
    @objc private func handleDoubleClick() { onDoubleClicked?(index) }

    // MARK: - Accessibility
    //
    // Same treatment as WindowCardView (see its Accessibility section):
    // a plain NSView reports itself as a button whose press action routes
    // through the SAME onClicked closure the mouse path (the click gesture
    // recognizer above) uses.

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? {
        let base = titleLabel.stringValue.isEmpty
            ? appNameLabel.stringValue
            : "\(appNameLabel.stringValue) — \(titleLabel.stringValue)"
        return "\(base), \(metaLabel.stringValue)"
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClicked else { return false }
        onClicked(index)
        return true
    }

    override func isAccessibilitySelected() -> Bool { selected }
}

// MARK: - FlippedView

/// NSView subclass with flipped coordinate system (y=0 at top).
/// Used as the container in NSScrollView so cards lay out top-to-bottom.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
