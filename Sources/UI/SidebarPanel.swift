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

    public static let expandedWidth: CGFloat = 76
    public static let collapsedWidth: CGFloat = 8
    private static let slotHeight: CGFloat = 64
    private static let slotSpacing: CGFloat = 4
    private static let sectionGap: CGFloat = 8
    private static let chromeHeight: CGFloat = 60   // chevron + overflow + paddings

    // MARK: Callbacks

    public var onWindowSelected: ((WindowInfo) -> Void)?
    public var onDeadPinActivated: ((Int) -> Void)?      // pinned index
    public var onOverflowRequested: (() -> Void)?
    public var onCollapseToggled: ((Bool) -> Void)?
    // Task 6 wires these:
    public var onPinRequested: ((WindowInfo) -> Void)?
    public var onUnpinRequested: ((Int) -> Void)?

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
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 10
        visualEffect.layer?.cornerCurve = .continuous
        visualEffect.layer?.masksToBounds = true
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
            orderOut(nil)
        } else if userWantsVisible {
            orderFrontRegardless()
        }
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

        chevronButton.bezelStyle = .inline
        chevronButton.isBordered = false
        chevronButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Collapse")
        chevronButton.target = self
        chevronButton.action = #selector(chevronTapped)

        overflowButton.bezelStyle = .inline
        overflowButton.isBordered = false
        overflowButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "All Windows")
        overflowButton.target = self
        overflowButton.action = #selector(overflowTapped)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -4),
        ])
    }

    private func rebuildSlots() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        slotViews.removeAll()
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

        let card = WindowCardView(appName: slot.appName, pid: slot.pid, thumbnail: slot.thumbnail)
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
        return card
    }

    private func makeSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: Self.expandedWidth - 20).isActive = true
        return box
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
        let slotCount = CGFloat(pinnedSlots.count + dynamicSlots.count)
        let height = collapsedNow
            ? 200
            : slotCount * (Self.slotHeight + Self.slotSpacing) + Self.chromeHeight
        let f = screen.visibleFrame
        setFrame(
            NSRect(x: f.maxX - width, y: f.midY - height / 2, width: width, height: height),
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
        guard isCollapsed, !isPeeking else { return }
        isPeeking = true
        rebuildSlots()
        reposition()
    }

    public override func mouseExited(with event: NSEvent) {
        guard isCollapsed, isPeeking else { return }
        isPeeking = false
        rebuildSlots()
        reposition()
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
