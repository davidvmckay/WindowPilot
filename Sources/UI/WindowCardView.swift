import AppKit

// MARK: - WindowThumbnailView

/// Thumbnail image view with the shared placeholder/live-image behavior
/// used by every card in the app (carousel, recent grid, sidebar slots).
public final class WindowThumbnailView: NSImageView {

    public init(thumbnail: CGImage?, cornerRadius: CGFloat = 6, maskedCorners: CACornerMask? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        if let maskedCorners { layer?.maskedCorners = maskedCorners }
        setThumbnail(thumbnail)
    }

    public required init?(coder: NSCoder) { fatalError() }

    public func setThumbnail(_ image: CGImage?) {
        if let image {
            self.image = NSImage(cgImage: image, size: .zero)
            imageScaling = .scaleProportionallyUpOrDown
        } else {
            self.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
            contentTintColor = .tertiaryLabelColor
            imageScaling = .scaleNone
        }
    }
}

// MARK: - WindowCardView

/// Shared card: thumbnail on top, optional app-icon + name row below,
/// accent selection border. Used by CarouselPanel and SidebarPanel.
public final class WindowCardView: NSView {

    public var onClicked: (() -> Void)?
    public var onDoubleClicked: (() -> Void)?
    public var onMouseEntered: (() -> Void)?
    public var onMouseExited: (() -> Void)?
    public var onDragEnded: ((NSPoint) -> Void)?   // screen point where drag ended
    private var pressOrigin: NSPoint?              // mouseDown location in window

    private let thumbnailView: WindowThumbnailView
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let showsLabelRow: Bool

    public init(appName: String, pid: Int32, thumbnail: CGImage?, showsLabelRow: Bool = true) {
        self.thumbnailView = WindowThumbnailView(thumbnail: thumbnail)
        self.showsLabelRow = showsLabelRow
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.clear.cgColor

        addSubview(thumbnailView)

        iconView.imageScaling = .scaleProportionallyDown
        if pid != 0, let app = NSRunningApplication(processIdentifier: pid) {
            iconView.image = app.icon
        }
        nameLabel.stringValue = appName
        nameLabel.font = .systemFont(ofSize: 10)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        if showsLabelRow {
            addSubview(iconView)
            addSubview(nameLabel)
        }

    }

    public required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        let w = bounds.width
        if showsLabelRow {
            let thumbH = bounds.height - 24
            thumbnailView.frame = NSRect(x: 4, y: 4, width: w - 8, height: thumbH - 4)
            iconView.frame = NSRect(x: 6, y: thumbH + 2, width: 14, height: 14)
            nameLabel.frame = NSRect(x: 22, y: thumbH + 1, width: w - 28, height: 16)
        } else {
            thumbnailView.frame = bounds.insetBy(dx: 4, dy: 4)
        }
    }

    public func setSelected(_ selected: Bool) {
        layer?.borderColor = selected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
            : nil
    }

    public func updateThumbnail(_ image: CGImage) {
        thumbnailView.setThumbnail(image)
    }

    public func setDimmed(_ dimmed: Bool) {
        alphaValue = dimmed ? 0.35 : 1.0
    }

    public override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    public override func mouseExited(with event: NSEvent) { onMouseExited?() }

    // The sidebar hosts these cards in a non-activating panel that never
    // becomes key. Without accepting first-mouse, AppKit swallows the initial
    // click in a non-key window as a focus attempt and the card never sees it —
    // which reads as "cards are unclickable" on some Macs. Accepting first mouse
    // and driving selection from mouseDown/mouseUp makes clicks deterministic
    // regardless of the host panel's key state. (Ctrl-click context menus are
    // unaffected: NSWindow.sendEvent routes them via menu(for:) before
    // mouseDown is ever dispatched.)
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        pressOrigin = event.locationInWindow
    }

    public override func mouseUp(with event: NSEvent) {
        defer { pressOrigin = nil }
        guard let origin = pressOrigin else { return }
        let travel = hypot(event.locationInWindow.x - origin.x,
                           event.locationInWindow.y - origin.y)
        if travel > 20, let window = self.window {
            onDragEnded?(window.convertPoint(toScreen: event.locationInWindow))
            return
        }
        // A few points of jitter is still a click; 4–20pt is an aborted drag
        // and must stay inert — otherwise a hesitant drag-to-pin released
        // short of the threshold would fire onClicked and switch windows.
        guard travel <= 4, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if event.clickCount >= 2 {
            onDoubleClicked?()
        } else {
            onClicked?()
        }
    }
}
