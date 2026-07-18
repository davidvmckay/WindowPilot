import AppKit
import WindowPilotCore

// MARK: - PilotPanel

/// The main floating panel for WindowPilot. Hosts the search bar, window tree,
/// screenshot preview, and action buttons.
///
/// - Does NOT become the active application (nonactivatingPanel) so the currently
///   focused app keeps its focus while the panel is visible.
/// - Overrides `canBecomeKey` so the embedded search field still receives keyboard input.
public final class PilotPanel: NSPanel {

    // MARK: Subviews

    private let tabBar = NSSegmentedControl()
    private let searchBar = SearchBar()
    private let treeView = TreeView()
    private let recentView = RecentView()
    private let previewView = PreviewView()
    private let actionBar = ActionBar()
    private let splitView = NSSplitView()
    private let rightStack = NSStackView()
    private let visualEffect = NSVisualEffectView()

    // MARK: State

    private var appNodes: [AppNode] = []
    /// Single source of truth for which window the ActionBar/preview act on.
    /// Internal (not private) read access exists solely so integration tests
    /// (`@testable import WindowPilotUI`) can assert there is no stale
    /// selection after a reload — external writes stay `private`.
    internal private(set) var selectedWindow: WindowInfo?
    private var clickOutsideMonitor: Any?
    private var showingRecent = false

    // MARK: Callbacks

    /// Called when the user selects a window in the tree (triggers preview capture).
    public var onWindowSelected: ((WindowInfo) -> Void)?

    /// Called when the user activates a window (Enter or double-click or Focus button).
    public var onWindowActivated: ((WindowInfo) -> Void)?

    /// Called when the search field text changes.
    public var onSearchChanged: ((String) -> Void)?

    /// Called when the user clicks Close on the selected window.
    public var onWindowClose: ((WindowInfo) -> Void)?

    /// Called when the user clicks Minimize on the selected window.
    public var onWindowMinimize: ((WindowInfo) -> Void)?

    /// Called when Esc is pressed in the search bar while it is empty.
    public var onDismissRequested: (() -> Void)?

    // MARK: Init

    public init() {
        let defaultRect = NSRect(x: 0, y: 0, width: 880, height: 560)
        // Panel chrome: NO .titled, NO .fullSizeContentView.
        //    .nonactivatingPanel: panel does not steal focus from other apps
        //    .resizable: user can resize the panel
        //    NO .titled: no title bar, no traffic lights, no title text
        //    NO .closable: close via Esc/hotkey instead
        //    NO .fullSizeContentView: without .titled this is a no-op per Apple docs,
        //        but on macOS 16 it can allocate a phantom title bar region that
        //        creates a visible artifact on full-screen dark backgrounds.
        let style: NSWindow.StyleMask = [
            .nonactivatingPanel,
            .resizable,
        ]
        super.init(
            contentRect: defaultRect,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        configurePanel()
        buildLayout()
        wireCallbacks()
    }

    // MARK: NSPanel overrides

    /// Allow the panel to become key so the search field can receive keyboard events even
    /// though the panel does not activate the application.
    public override var canBecomeKey: Bool { true }

    // MARK: Public API

    /// Update screen recording permission state for preview placeholder.
    public func updateScreenRecordingPermission(_ hasPermission: Bool) {
        previewView.hasScreenRecordingPermission = hasPermission
    }

    /// Display a captured screenshot in the preview pane.
    public func showPreview(image: CGImage?) {
        previewView.showPreview(image: image)
    }

    /// Reload the tree with a new set of app nodes (e.g. after filtering).
    public func reloadTree(apps: [AppNode]) {
        treeView.reloadData(apps: apps)

        // TreeView.reloadData only fires onWindowSelected when the reload lands
        // on a real window (see TreeView.reloadData). When a filter matches
        // nothing, selectedWindowInfo goes nil and no callback fires, so
        // `selectedWindow` would otherwise keep pointing at a window the user
        // can no longer see — the ActionBar's Focus/Close/Minimize would then
        // act on an invisible window. Resync here, but only when All Windows is
        // the tab actually on screen: a background tree reload (e.g. while the
        // Recent tab is showing) must not clobber a Recent-tab selection.
        guard !showingRecent else { return }
        resyncSelectionToVisibleTab()
    }

    /// Show the panel. If recent data is available, show Recent tab; otherwise All Windows.
    public func show(
        apps: [AppNode],
        recentWindows: [TrackedWindow] = [],
        thumbnails: [UInt32: CGImage] = [:]
    ) {
        appNodes = apps
        treeView.reloadData(apps: apps)

        if !recentWindows.isEmpty {
            recentView.reloadData(windows: recentWindows, thumbnails: thumbnails)
            switchToTab(recent: true)
        } else {
            switchToTab(recent: false)
        }

        centerOnCursorScreen()
        makeKeyAndOrderFront(nil)
        if showingRecent {
            makeFirstResponder(recentView)
            recentView.selectInitialCard()
        } else {
            searchBar.focusSearchField()
        }
        startClickOutsideMonitor()
    }

    /// Update recent view thumbnails (called after background refresh).
    public func updateRecentThumbnails(_ thumbnails: [UInt32: CGImage]) {
        recentView.updateThumbnails(thumbnails)
    }

    /// Hide the panel without destroying it.
    /// Preserves the tree expand/collapse state so the next show() is instant.
    public func dismiss() {
        stopClickOutsideMonitor()
        previewView.clearPreview()
        orderOut(nil)
    }

    // MARK: - Private helpers

    private func configurePanel() {
        // No .titled → no title bar to configure. Do NOT set
        // titlebarAppearsTransparent or titleVisibility — they can cause
        // macOS to allocate a phantom title bar region.
        isMovableByWindowBackground = true
        level = .floating
        isReleasedWhenClosed = false

        // ✅ FIX 2: Change from .canJoinAllSpaces to .moveToActiveSpace
        //
        //    .canJoinAllSpaces means the panel exists on ALL Spaces simultaneously,
        //    including full-screen Spaces. Even after orderOut(), macOS still considers
        //    it "present" on the full-screen Space, which prevents proper Space-switch
        //    animations when focusing a normal window.
        //
        //    .moveToActiveSpace means the panel only exists on whichever Space was
        //    active when show() was called. After dismiss(), it's truly gone from
        //    that Space, allowing CGS/SkyLight to do clean Space transitions.
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        // Visual effect view fills the entire content area
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        contentView = visualEffect

        // Rounded corners: transparent window + layer masking on content
        backgroundColor = .clear
        isOpaque = false
        visualEffect.applyRoundedCorners(radius: 10)
    }

    private func buildLayout() {
        guard let contentView else { return }

        // --- Tab bar ---
        tabBar.segmentCount = 2
        tabBar.setLabel("Recent", forSegment: 0)
        tabBar.setLabel("All Windows", forSegment: 1)
        tabBar.segmentStyle = .texturedRounded
        tabBar.selectedSegment = 1
        tabBar.target = self
        tabBar.action = #selector(tabChanged)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabBar)

        // --- Search bar ---
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(searchBar)

        // --- Split view (for All Windows mode) ---
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(splitView)

        // Left pane: tree view
        let leftContainer = NSView()
        leftContainer.translatesAutoresizingMaskIntoConstraints = false
        treeView.translatesAutoresizingMaskIntoConstraints = false
        leftContainer.addSubview(treeView)
        NSLayoutConstraint.activate([
            treeView.topAnchor.constraint(equalTo: leftContainer.topAnchor),
            treeView.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor),
            treeView.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor),
            treeView.bottomAnchor.constraint(equalTo: leftContainer.bottomAnchor),
        ])

        // Right pane: preview (flex) + action bar (44px)
        rightStack.orientation = .vertical
        rightStack.spacing = 0
        rightStack.distribution = .fill
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        previewView.translatesAutoresizingMaskIntoConstraints = false
        actionBar.translatesAutoresizingMaskIntoConstraints = false

        rightStack.addArrangedSubview(previewView)
        rightStack.addArrangedSubview(actionBar)

        actionBar.heightAnchor.constraint(equalToConstant: 44).isActive = true

        splitView.addArrangedSubview(leftContainer)
        splitView.addArrangedSubview(rightStack)

        leftContainer.widthAnchor.constraint(equalToConstant: 280).isActive = true

        // --- Recent view (for Recent mode, replaces the split view) ---
        recentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(recentView)
        recentView.isHidden = true

        NSLayoutConstraint.activate([
            // Tab bar at the very top
            tabBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            tabBar.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            // Search bar below tab bar
            searchBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 4),
            searchBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: 40),

            // Split view (All Windows mode)
            splitView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // Recent view (Recent mode) — same position as split view
            recentView.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 4),
            recentView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            recentView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            recentView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @objc private func tabChanged() {
        switchToTab(recent: tabBar.selectedSegment == 0)
    }

    private func switchToTab(recent: Bool) {
        showingRecent = recent
        tabBar.selectedSegment = recent ? 0 : 1

        recentView.isHidden = !recent
        splitView.isHidden = recent
        searchBar.isHidden = recent

        if recent {
            makeFirstResponder(recentView)
        } else {
            searchBar.focusSearchField()
        }

        // Resync the selection single source of truth to the now-visible view.
        // Without this, ActionBar/preview keep acting on the other tab's window
        // (the confirmed selection-desync bug).
        resyncSelectionToVisibleTab()
    }

    /// Resync `selectedWindow` (and the preview/action bar it drives) to whichever
    /// view is currently visible (`recentView` or `treeView`). Only fires
    /// `onWindowSelected` when the effective selection actually changed, so
    /// callers that just resync after a no-op reload don't cause a spurious
    /// preview reload.
    private func resyncSelectionToVisibleTab() {
        let previous = selectedWindow
        let current = showingRecent ? recentView.selectedWindowInfo : treeView.selectedWindowInfo
        selectedWindow = current
        if let win = current {
            if win != previous {
                onWindowSelected?(win)
                actionBar.updateForState(win.state)
            }
        } else {
            // Nothing selected in the visible tab: clear the preview and reset
            // the action buttons to a safe (neutral) state.
            previewView.clearPreview()
            actionBar.updateForState(.normal)
        }
    }

    private func wireCallbacks() {
        // Search bar → filter tree
        searchBar.onTextChanged = { [weak self] query in
            self?.onSearchChanged?(query)
        }
        searchBar.onEscapeWhenEmpty = { [weak self] in
            self?.onDismissRequested?()
        }

        // Tree selection → load preview + update action bar
        treeView.onWindowSelected = { [weak self] windowInfo in
            self?.selectedWindow = windowInfo
            self?.actionBar.updateForState(windowInfo.state)
            self?.onWindowSelected?(windowInfo)
        }

        // Tree activation → focus window
        treeView.onWindowActivated = { [weak self] windowInfo in
            self?.selectedWindow = windowInfo
            self?.onWindowActivated?(windowInfo)
        }

        // Recent view selection → load preview
        recentView.onWindowSelected = { [weak self] windowInfo in
            self?.selectedWindow = windowInfo
            self?.onWindowSelected?(windowInfo)
        }

        // Recent view activation → focus window
        recentView.onWindowActivated = { [weak self] windowInfo in
            self?.selectedWindow = windowInfo
            self?.onWindowActivated?(windowInfo)
        }

        // Action bar buttons
        actionBar.onFocusTapped = { [weak self] in
            guard let win = self?.selectedWindow else { return }
            self?.onWindowActivated?(win)
        }
        actionBar.onCloseTapped = { [weak self] in
            guard let win = self?.selectedWindow else { return }
            self?.onWindowClose?(win)
        }
        actionBar.onMinimizeTapped = { [weak self] in
            guard let win = self?.selectedWindow else { return }
            self?.onWindowMinimize?(win)
        }
    }

    private func startClickOutsideMonitor() {
        stopClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.onDismissRequested?()
        }
    }

    private func stopClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    /// Center the panel on whichever screen currently contains the mouse pointer.
    private func centerOnCursorScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        let screenFrame = screen.visibleFrame
        let panelSize = frame.size
        let origin = NSPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.midY - panelSize.height / 2
        )
        setFrameOrigin(origin)
    }
}

// MARK: - ActionBar

/// The thin toolbar at the bottom-right of the panel.
/// Contains Focus (primary), Close, and Minimize buttons.
public final class ActionBar: NSView {

    public var onFocusTapped: (() -> Void)?
    public var onCloseTapped: (() -> Void)?
    public var onMinimizeTapped: (() -> Void)?

    private let focusButton = NSButton()
    private let closeButton = NSButton()
    private let minimizeButton = NSButton()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildLayout()
    }

    private func buildLayout() {
        // Subtle separator line at the top
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        // Configure buttons
        configure(button: focusButton, title: "Focus", isAccent: true)
        configure(button: closeButton, title: "Close", isAccent: false)
        configure(button: minimizeButton, title: "Minimize", isAccent: false)

        focusButton.target = self
        focusButton.action = #selector(focusTapped)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        minimizeButton.target = self
        minimizeButton.action = #selector(minimizeTapped)

        let stack = NSStackView(views: [minimizeButton, closeButton, focusButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func configure(button: NSButton, title: String, isAccent: Bool) {
        button.title = title
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        if isAccent {
            button.hasDestructiveAction = false
            button.keyEquivalent = "\r"
            // Accent color — bezelColor gives the blue appearance on macOS 14+
            if #available(macOS 14.0, *) {
                button.bezelColor = NSColor.controlAccentColor
            }
        }
    }

    /// Update button states based on the selected window's state.
    public func updateForState(_ state: WindowState) {
        minimizeButton.isEnabled = state != .minimized
        minimizeButton.title = state == .minimized ? "Minimized" : "Minimize"
    }

    @objc private func focusTapped() { onFocusTapped?() }
    @objc private func closeTapped() { onCloseTapped?() }
    @objc private func minimizeTapped() { onMinimizeTapped?() }
}
