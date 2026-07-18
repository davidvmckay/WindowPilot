import AppKit
import WindowPilotCore

// MARK: - SidebarSlot

/// One rendered position in the sidebar.
public struct SidebarSlot {
    public enum Kind { case pinned, dynamic }
    public let kind: Kind
    public let index: Int                // position within its zone
    public let window: WindowInfo?       // nil = empty position or dead pin
    public let appName: String           // "" for empty positions
    public let pid: Int32                // 0 when unknown/dead
    public let thumbnail: CGImage?
    public let isDeadPin: Bool

    public init(kind: Kind, index: Int, window: WindowInfo?, appName: String,
                pid: Int32, thumbnail: CGImage?, isDeadPin: Bool = false) {
        self.kind = kind
        self.index = index
        self.window = window
        self.appName = appName
        self.pid = pid
        self.thumbnail = thumbnail
        self.isDeadPin = isDeadPin
    }
}

// MARK: - SidebarPanel

/// Optional persistent work strip. Non-activating, never key, floats on
/// the right edge of a chosen display. Pinned zone on top (fixed positions),
/// parking-lot dynamic zone below, overflow button at the bottom.
public final class SidebarPanel: NSPanel {

    public static let expandedWidth: CGFloat = 128
    public static let collapsedWidth: CGFloat = 10
    private static let collapsedHeight: CGFloat = 64
    private static let slotHeight: CGFloat = 96
    private static let slotSpacing: CGFloat = 6
    /// One slot's vertical footprint — used by the capacity calculation.
    public static var slotUnit: CGFloat { slotHeight + slotSpacing }
    private static let contentPadding: CGFloat = 12   // breathing room above/below content
    private static let edgeInset: CGFloat = 8         // gap between strip and screen edge when expanded

    // MARK: Callbacks

    public var onWindowSelected: ((WindowInfo) -> Void)?
    public var onDeadPinActivated: ((Int) -> Void)?      // pinned index
    public var onOverflowRequested: (() -> Void)?
    public var onCollapseToggled: ((Bool) -> Void)?
    // Task 6 wires these:
    public var onPinRequested: ((WindowInfo) -> Void)?
    public var onUnpinRequested: ((Int) -> Void)?
    public var onWindowClosed: ((WindowInfo) -> Void)?
    public var onWindowMinimized: ((WindowInfo) -> Void)?

    // MARK: State

    public private(set) var isCollapsed = false
    private var isPeeking = false                        // hover-expanded while collapsed
    private var pinnedSlots: [SidebarSlot] = []
    private var dynamicSlots: [SidebarSlot] = []
    private var slotViews: [(slot: SidebarSlot, view: WindowCardView)] = []
    private var focusedWindowID: UInt32?
    private var targetScreen: NSScreen?
    private var suppressedForFullscreen = false
    private var userWantsVisible = false

    private let visualEffect = NSVisualEffectView()
    private let stack = NSStackView()
    private let chevronButton = NSButton()
    private let overflowButton = NSButton()
    private let grabber = NSView()                       // capsule handle shown when collapsed
    private var collapseWorkItem: DispatchWorkItem?      // debounces peek collapse

    // MARK: Init

    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.expandedWidth, height: 400),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isReleasedWhenClosed = false
        // Spike decision (2026-07-16): proven-safe default; upgrade to
        // .canJoinAllSpaces is a one-line change pending a manual re-check.
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.applyRoundedCorners(radius: 12)
        // Subtle hairline border lifts the strip off busy backgrounds.
        visualEffect.layer?.borderWidth = 1
        visualEffect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        contentView = visualEffect

        buildLayout()
        updateTrackingArea()
    }

    /// The strip is furniture, not a window: it must never become key.
    public override var canBecomeKey: Bool { false }

    // MARK: Public API

    public func show(on screen: NSScreen?) {
        targetScreen = screen ?? NSScreen.main
        userWantsVisible = true
        reposition()
        if !suppressedForFullscreen {
            orderFrontRegardless()
        }
    }

    public func hide() {
        userWantsVisible = false
        hideHoverPreview()
        orderOut(nil)
    }

    public func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        isPeeking = false
        applyCollapseState()
    }

    /// Auto-hide over fullscreen on our display (driven by AppDelegate).
    public func setHiddenForFullscreen(_ hidden: Bool) {
        suppressedForFullscreen = hidden
        if hidden {
            hideHoverPreview()
            orderOut(nil)
        } else if userWantsVisible {
            orderFrontRegardless()
        }
    }

    /// Reattach after a Space switch (moveToActiveSpace leaves the strip on
    /// the previous Space). Respects mode state and fullscreen suppression —
    /// never un-hides a strip that is suppressed over a fullscreen app.
    public func reattachToActiveSpace() {
        guard userWantsVisible, !suppressedForFullscreen else { return }
        orderFrontRegardless()
    }

    public func render(pinned: [SidebarSlot], dynamic: [SidebarSlot], focusedWindowID: UInt32?) {
        pinnedSlots = pinned
        dynamicSlots = dynamic
        self.focusedWindowID = focusedWindowID
        rebuildSlots()
        reposition()
    }

    public func updateThumbnails(_ thumbnails: [UInt32: CGImage]) {
        for (slot, view) in slotViews {
            guard let wid = slot.window?.id, let img = thumbnails[wid] else { continue }
            view.updateThumbnail(img)
        }
    }

    public var currentScreen: NSScreen? { targetScreen }

    // MARK: Layout

    private func buildLayout() {
        stack.orientation = .vertical
        stack.spacing = Self.slotSpacing
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(stack)

        let smallSymbol = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)

        chevronButton.bezelStyle = .inline
        chevronButton.isBordered = false
        chevronButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Collapse")?
            .withSymbolConfiguration(smallSymbol)
        chevronButton.contentTintColor = .tertiaryLabelColor
        chevronButton.target = self
        chevronButton.action = #selector(chevronTapped)

        overflowButton.bezelStyle = .inline
        overflowButton.isBordered = false
        overflowButton.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "All Windows")?
            .withSymbolConfiguration(smallSymbol)
        overflowButton.contentTintColor = .tertiaryLabelColor
        overflowButton.target = self
        overflowButton.action = #selector(overflowTapped)

        // Capsule handle for the collapsed state — reads as "something is
        // tucked here", not as leftover chrome.
        grabber.wantsLayer = true
        grabber.layer?.cornerRadius = 2
        grabber.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55).cgColor
        grabber.translatesAutoresizingMaskIntoConstraints = false
        grabber.isHidden = true
        visualEffect.addSubview(grabber)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: Self.contentPadding),
            stack.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -4),

            grabber.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
            grabber.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 4),
            grabber.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func rebuildSlots() {
        hideHoverPreview()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        slotViews.removeAll()
        grabber.isHidden = !collapsedNow
        // Collapsed = quiet capsule handle: no border, tighter radius.
        visualEffect.layer?.borderWidth = collapsedNow ? 0 : 1
        visualEffect.applyRoundedCorners(radius: collapsedNow ? 5 : 12)
        guard !collapsedNow else { return }

        stack.addArrangedSubview(chevronButton)

        for slot in pinnedSlots {
            stack.addArrangedSubview(makeSlotView(slot))
        }
        if !pinnedSlots.isEmpty && !dynamicSlots.isEmpty {
            stack.addArrangedSubview(makeSeparator())
        }
        for slot in dynamicSlots {
            stack.addArrangedSubview(makeSlotView(slot))
        }
        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(overflowButton)
    }

    private func makeSlotView(_ slot: SidebarSlot) -> NSView {
        // Empty position: subtle dashed placeholder that HOLDS the position
        // (spatial stability means empty positions still occupy space).
        guard slot.window != nil || slot.isDeadPin else {
            let empty = NSView()
            empty.wantsLayer = true
            empty.layer?.cornerRadius = 8
            empty.layer?.borderWidth = 1
            empty.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor
            empty.widthAnchor.constraint(equalToConstant: Self.expandedWidth - 8).isActive = true
            empty.heightAnchor.constraint(equalToConstant: Self.slotHeight).isActive = true
            return empty
        }

        let card = WindowCardView(appName: slot.appName, windowTitle: slot.window?.title ?? "", pid: slot.pid, thumbnail: slot.thumbnail)
        card.widthAnchor.constraint(equalToConstant: Self.expandedWidth - 8).isActive = true
        card.heightAnchor.constraint(equalToConstant: Self.slotHeight).isActive = true
        if let window = slot.window {
            card.setSelected(window.id == focusedWindowID)
            card.onClicked = { [weak self] in self?.onWindowSelected?(window) }
        } else {
            card.setDimmed(true)
            let pinIndex = slot.index
            card.onClicked = { [weak self] in self?.onDeadPinActivated?(pinIndex) }
        }
        slotViews.append((slot, card))
        card.menu = makeContextMenu(for: slot)
        if let window = slot.window {
            let hoverArea = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: card, userInfo: nil
            )
            card.addTrackingArea(hoverArea)
            card.onMouseEntered = { [weak self, weak card] in
                guard let self, let card else { return }
                self.showHoverPreview(for: window, near: card)
            }
            card.onMouseExited = { [weak self] in self?.hideHoverPreview() }
        }
        if slot.kind == .dynamic, let window = slot.window {
            card.onDragEnded = { [weak self] screenPoint in
                guard let self else { return }
                // Dropped inside the pinned zone's vertical range?
                let pinnedBottom = self.pinnedZoneBottomOnScreen()
                if screenPoint.y > pinnedBottom {
                    self.onPinRequested?(window)
                }
            }
        }
        return card
    }

    private func makeSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: Self.expandedWidth - 20).isActive = true
        return box
    }

    // MARK: Context menu

    private func makeContextMenu(for slot: SidebarSlot) -> NSMenu {
        let menu = NSMenu()
        if slot.kind == .dynamic, let window = slot.window {
            let pinItem = NSMenuItem(title: "Pin", action: #selector(menuPin(_:)), keyEquivalent: "")
            pinItem.target = self
            pinItem.representedObject = window
            menu.addItem(pinItem)
        }
        if slot.kind == .pinned {
            let unpinItem = NSMenuItem(title: "Unpin", action: #selector(menuUnpin(_:)), keyEquivalent: "")
            unpinItem.target = self
            unpinItem.representedObject = slot.index
            menu.addItem(unpinItem)
        }
        if let window = slot.window {
            menu.addItem(.separator())
            let closeItem = NSMenuItem(title: "Close Window", action: #selector(menuClose(_:)), keyEquivalent: "")
            closeItem.target = self
            closeItem.representedObject = window
            menu.addItem(closeItem)
            let minItem = NSMenuItem(title: "Minimize", action: #selector(menuMinimize(_:)), keyEquivalent: "")
            minItem.target = self
            minItem.representedObject = window
            menu.addItem(minItem)
        }
        return menu
    }

    @objc private func menuPin(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? WindowInfo else { return }
        onPinRequested?(window)
    }

    @objc private func menuUnpin(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        onUnpinRequested?(index)
    }

    @objc private func menuClose(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? WindowInfo else { return }
        onWindowClosed?(window)
    }

    @objc private func menuMinimize(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? WindowInfo else { return }
        onWindowMinimized?(window)
    }

    // MARK: Hover preview

    private var previewPanel: NSPanel?

    private func showHoverPreview(for window: WindowInfo, near view: NSView) {
        hideHoverPreview()
        guard let thumbnail = slotViews.first(where: { $0.slot.window?.id == window.id })?.slot.thumbnail
        else { return }

        let maxSize = NSSize(width: 360, height: 240)
        let aspect = CGFloat(thumbnail.width) / max(CGFloat(thumbnail.height), 1)
        let size = aspect > maxSize.width / maxSize.height
            ? NSSize(width: maxSize.width, height: maxSize.width / aspect)
            : NSSize(width: maxSize.height * aspect, height: maxSize.height)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true

        let imageView = WindowThumbnailView(thumbnail: thumbnail, cornerRadius: 8)
        imageView.frame = NSRect(origin: .zero, size: size)
        panel.contentView = imageView

        // Place to the left of the strip, vertically centered on the slot.
        let slotFrameInWindow = view.convert(view.bounds, to: nil)
        let slotFrameOnScreen = convertToScreen(slotFrameInWindow)
        panel.setFrameOrigin(NSPoint(
            x: frame.minX - size.width - 8,
            y: slotFrameOnScreen.midY - size.height / 2
        ))
        panel.orderFrontRegardless()
        previewPanel = panel
    }

    private func hideHoverPreview() {
        previewPanel?.orderOut(nil)
        previewPanel = nil
    }

    /// Screen-Y of the bottom of the pinned zone (top `pinnedSlots.count`
    /// slots + chevron). Drops above this line count as "into the pinned zone".
    private func pinnedZoneBottomOnScreen() -> CGFloat {
        let pinnedHeight = CGFloat(pinnedSlots.count) * (Self.slotHeight + Self.slotSpacing) + 30
        return frame.maxY - pinnedHeight
    }

    // MARK: Collapse / hot edge

    private var collapsedNow: Bool { isCollapsed && !isPeeking }

    private func applyCollapseState() {
        chevronButton.image = NSImage(
            systemSymbolName: isCollapsed ? "chevron.left" : "chevron.right",
            accessibilityDescription: isCollapsed ? "Expand" : "Collapse"
        )
        rebuildSlots()
        reposition()
        updateTrackingArea()
    }

    private func reposition() {
        guard let screen = targetScreen ?? NSScreen.main else { return }
        let width = collapsedNow ? Self.collapsedWidth : Self.expandedWidth
        // Height follows the actual stack content (slots + separators + buttons),
        // so nothing at the bottom ever gets clipped by a fixed allowance.
        let height: CGFloat
        if collapsedNow {
            height = Self.collapsedHeight
        } else {
            stack.layoutSubtreeIfNeeded()
            height = stack.fittingSize.height + Self.contentPadding * 2
        }
        let f = screen.visibleFrame
        // Only a deliberately expanded strip floats off the edge. While
        // collapsed OR peeking it stays flush, so the cursor at the screen
        // edge remains inside the panel — otherwise peek-expansion opens a
        // gap under the cursor, fires mouseExited, and the strip flickers.
        let inset: CGFloat = isCollapsed ? 0 : Self.edgeInset
        setFrame(
            NSRect(
                x: f.maxX - width - inset,
                y: f.midY - height / 2, width: width, height: height
            ),
            display: true
        )
    }

    private var trackingArea: NSTrackingArea?

    private func updateTrackingArea() {
        if let ta = trackingArea { visualEffect.removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: visualEffect.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        visualEffect.addTrackingArea(ta)
        trackingArea = ta
    }

    public override func mouseEntered(with event: NSEvent) {
        collapseWorkItem?.cancel()
        guard isCollapsed, !isPeeking else { return }
        isPeeking = true
        rebuildSlots()
        reposition()
    }

    public override func mouseExited(with event: NSEvent) {
        guard isCollapsed, isPeeking else { return }
        // Debounce: brief excursions (crossing to a hover preview, grazing
        // the edge) shouldn't snap the strip shut.
        collapseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isCollapsed, self.isPeeking else { return }
            self.isPeeking = false
            self.rebuildSlots()
            self.reposition()
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: Actions

    @objc private func chevronTapped() {
        setCollapsed(!isCollapsed)
        onCollapseToggled?(isCollapsed)
    }

    @objc private func overflowTapped() {
        onOverflowRequested?()
    }
}
