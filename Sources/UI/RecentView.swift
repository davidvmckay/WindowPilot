import AppKit
import WindowPilotCore

// MARK: - RecentView

/// Scrollable list of most recently used windows with thumbnail previews.
/// Each row shows: screenshot thumbnail, app icon, app name, window title,
/// total duration, and "ago" text.
public final class RecentView: NSView {

    // MARK: Callbacks

    /// Called when a row is selected (single click).
    public var onWindowSelected: ((WindowInfo) -> Void)?

    /// Called when a row is activated (double-click or Enter).
    public var onWindowActivated: ((WindowInfo) -> Void)?

    // MARK: Subviews

    private let scrollView = NSScrollView()
    private let stackView = NSStackView()

    // MARK: State

    private var trackedWindows: [TrackedWindow] = []
    private var thumbnails: [UInt32: CGImage] = [:]
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

    /// Reload the list with new tracked window data and thumbnails.
    public func reloadData(
        windows: [TrackedWindow],
        thumbnails: [UInt32: CGImage]
    ) {
        self.trackedWindows = windows
        self.thumbnails = thumbnails
        selectedIndex = -1
        rebuildRows()
    }

    /// Update thumbnails without rebuilding the entire view.
    public func updateThumbnails(_ newThumbnails: [UInt32: CGImage]) {
        for (wid, image) in newThumbnails {
            thumbnails[wid] = image
        }
        // Update existing thumbnail views
        for (i, view) in stackView.arrangedSubviews.enumerated() {
            guard i < trackedWindows.count,
                  let row = view as? RecentRowView,
                  let newImage = newThumbnails[trackedWindows[i].id] else { continue }
            row.updateThumbnail(newImage)
        }
    }

    // MARK: Keyboard

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: // Down arrow
            selectRow(at: min(selectedIndex + 1, trackedWindows.count - 1))
        case 126: // Up arrow
            selectRow(at: max(selectedIndex - 1, 0))
        case 36: // Enter
            if selectedIndex >= 0, selectedIndex < trackedWindows.count {
                let tracked = trackedWindows[selectedIndex]
                onWindowActivated?(windowInfo(from: tracked))
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Private

    private func buildLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        stackView.orientation = .vertical
        stackView.spacing = 1
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.setHuggingPriority(.defaultLow, for: .horizontal)

        let clipView = NSClipView()
        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.drawsBackground = false
        clipView.documentView = stackView
        scrollView.contentView = clipView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.topAnchor.constraint(equalTo: clipView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            stackView.widthAnchor.constraint(equalTo: clipView.widthAnchor),
        ])
    }

    private func rebuildRows() {
        // Remove old rows
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if trackedWindows.isEmpty {
            let label = NSTextField(labelWithString: "No recent windows yet")
            label.textColor = .tertiaryLabelColor
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(label)
            label.heightAnchor.constraint(equalToConstant: 80).isActive = true
            return
        }

        for (index, tracked) in trackedWindows.enumerated() {
            let row = RecentRowView(
                tracked: tracked,
                thumbnail: thumbnails[tracked.id],
                index: index
            )
            row.onClicked = { [weak self] idx in
                self?.selectRow(at: idx)
            }
            row.onDoubleClicked = { [weak self] idx in
                guard let self, idx < self.trackedWindows.count else { return }
                self.onWindowActivated?(self.windowInfo(from: self.trackedWindows[idx]))
            }
            stackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
        }
    }

    private func selectRow(at index: Int) {
        guard index >= 0, index < trackedWindows.count else { return }

        // Deselect old
        if selectedIndex >= 0, selectedIndex < stackView.arrangedSubviews.count,
           let oldRow = stackView.arrangedSubviews[selectedIndex] as? RecentRowView {
            oldRow.setSelected(false)
        }

        selectedIndex = index

        // Select new
        if let newRow = stackView.arrangedSubviews[index] as? RecentRowView {
            newRow.setSelected(true)
        }

        let tracked = trackedWindows[index]
        onWindowSelected?(windowInfo(from: tracked))
    }

    private func windowInfo(from tracked: TrackedWindow) -> WindowInfo {
        WindowInfo(
            id: tracked.id,
            ownerPID: tracked.pid,
            title: tracked.windowTitle,
            bounds: .zero,
            state: .normal  // MRU doesn't track state; focus logic re-detects
        )
    }
}

// MARK: - RecentRowView

/// A single row in the RecentView list.
final class RecentRowView: NSView {

    var onClicked: ((Int) -> Void)?
    var onDoubleClicked: ((Int) -> Void)?

    private let index: Int
    private let thumbnailView = NSImageView()
    private let appIconView = NSImageView()
    private let appNameLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let highlightView = NSView()

    init(tracked: TrackedWindow, thumbnail: CGImage?, index: Int) {
        self.index = index
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 72).isActive = true

        // Highlight background
        highlightView.translatesAutoresizingMaskIntoConstraints = false
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 6
        highlightView.isHidden = true
        addSubview(highlightView)

        // Thumbnail
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 4
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.borderWidth = 0.5
        thumbnailView.layer?.borderColor = NSColor.separatorColor.cgColor
        if let thumbnail {
            thumbnailView.image = NSImage(cgImage: thumbnail, size: NSSize(width: 120, height: 75))
        } else {
            thumbnailView.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
            thumbnailView.contentTintColor = .tertiaryLabelColor
        }
        addSubview(thumbnailView)

        // App icon
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        appIconView.imageScaling = .scaleProportionallyDown
        if let app = NSRunningApplication(processIdentifier: tracked.pid) {
            appIconView.image = app.icon
        }
        addSubview(appIconView)

        // App name
        appNameLabel.translatesAutoresizingMaskIntoConstraints = false
        appNameLabel.stringValue = tracked.appName
        appNameLabel.textColor = .secondaryLabelColor
        appNameLabel.font = .systemFont(ofSize: 11)
        appNameLabel.lineBreakMode = .byTruncatingTail
        addSubview(appNameLabel)

        // Window title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = tracked.windowTitle
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        // Meta (duration + ago)
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.stringValue = "\(tracked.durationText) total  ·  \(tracked.agoText)"
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.font = .systemFont(ofSize: 11)
        addSubview(metaLabel)

        NSLayoutConstraint.activate([
            highlightView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 100),
            thumbnailView.heightAnchor.constraint(equalToConstant: 56),

            appIconView.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 10),
            appIconView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            appIconView.widthAnchor.constraint(equalToConstant: 16),
            appIconView.heightAnchor.constraint(equalToConstant: 16),

            appNameLabel.leadingAnchor.constraint(equalTo: appIconView.trailingAnchor, constant: 4),
            appNameLabel.centerYAnchor.constraint(equalTo: appIconView.centerYAnchor),
            appNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            titleLabel.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: appNameLabel.bottomAnchor, constant: 3),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            metaLabel.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 10),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])

        // Click gesture
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
        click.delaysPrimaryMouseButtonEvents = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool) {
        highlightView.isHidden = !selected
        highlightView.layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            : nil
    }

    func updateThumbnail(_ image: CGImage) {
        thumbnailView.image = NSImage(cgImage: image, size: NSSize(width: 120, height: 75))
    }

    @objc private func handleClick() { onClicked?(index) }
    @objc private func handleDoubleClick() { onDoubleClicked?(index) }
}
