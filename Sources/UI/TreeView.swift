import AppKit
import WindowPilotCore

// MARK: - TreeView

/// Two-level NSOutlineView wrapper.
/// Level 1 (group): AppNode  — icon + name + window count badge
/// Level 2 (leaf):  WindowInfo — colored dot + truncated title
public final class TreeView: NSView {

    // MARK: Subviews

    private let scrollView = NSScrollView()
    private let outlineView = KeyableOutlineView()

    // MARK: State

    private var apps: [AppNode] = []
    private var expandedPIDs: Set<Int32> = []
    private var iconCache: [Int32: NSImage] = [:]

    // MARK: Callbacks

    public var onWindowSelected: ((WindowInfo) -> Void)?
    public var onWindowActivated: ((WindowInfo) -> Void)?

    // MARK: Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: Public API

    /// Replace current data, preserve expand/collapse state, re-select if possible.
    public func reloadData(apps: [AppNode]) {
        // Save currently expanded PIDs before the reload
        let previouslyExpanded = expandedPIDs
        let isFirstLoad = self.apps.isEmpty

        self.apps = apps

        // Clear icon cache entries for PIDs that are no longer present
        let currentPIDs = Set(apps.map(\.id))
        iconCache = iconCache.filter { currentPIDs.contains($0.key) }

        outlineView.reloadData()

        if isFirstLoad {
            // Expand all groups on first load
            for app in apps {
                outlineView.expandItem(app)
                expandedPIDs.insert(app.id)
            }
        } else {
            // Restore previously expanded state
            for app in apps {
                if previouslyExpanded.contains(app.id) {
                    outlineView.expandItem(app)
                    expandedPIDs.insert(app.id)
                }
            }
        }

        // Select first leaf item if nothing is currently selected
        if outlineView.selectedRow == -1 {
            selectFirstLeaf()
        }
    }

    // MARK: Private setup

    private func setup() {
        // Configure scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Configure outline view
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.headerView = nil
        outlineView.rowSizeStyle = .custom
        outlineView.indentationPerLevel = 16
        outlineView.selectionHighlightStyle = .regular
        outlineView.backgroundColor = .clear
        outlineView.floatsGroupRows = false
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false

        outlineView.dataSource = self
        outlineView.delegate = self

        // Double-click to activate
        outlineView.target = self
        outlineView.doubleAction = #selector(handleDoubleClick)

        // Enter key activation via subclass callback
        outlineView.onEnterKey = { [weak self] in
            self?.activateSelectedWindow()
        }

        scrollView.documentView = outlineView
        outlineView.sizeLastColumnToFit()
    }

    // MARK: Private helpers

    private func selectFirstLeaf() {
        for (section, app) in apps.enumerated() {
            _ = section
            guard !app.windows.isEmpty else { continue }
            // Find the row for the first window of this app
            let appRow = outlineView.row(forItem: app)
            if appRow == -1 { continue }
            // First child row
            let childRow = outlineView.row(forItem: app.windows[0])
            if childRow >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: childRow), byExtendingSelection: false)
                return
            }
        }
    }

    private func windowInfo(atRow row: Int) -> WindowInfo? {
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? WindowInfo
    }

    private func activateSelectedWindow() {
        guard let win = windowInfo(atRow: outlineView.selectedRow) else { return }
        onWindowActivated?(win)
    }

    @objc private func handleDoubleClick() {
        activateSelectedWindow()
    }

    private func icon(for app: AppNode) -> NSImage {
        if let cached = iconCache[app.id] { return cached }
        let image: NSImage
        if let running = NSRunningApplication(processIdentifier: app.id),
           let icon = running.icon {
            image = icon
        } else {
            image = NSWorkspace.shared.icon(forFile: "/Applications")
        }
        image.size = NSSize(width: 16, height: 16)
        iconCache[app.id] = image
        return image
    }
}

// MARK: - NSOutlineViewDataSource

extension TreeView: NSOutlineViewDataSource {

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return apps.count
        }
        if let app = item as? AppNode {
            return app.windows.count
        }
        return 0
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return apps[index]
        }
        if let app = item as? AppNode {
            return app.windows[index]
        }
        // Unreachable for a two-level tree
        fatalError("Unexpected item type in TreeView data source")
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is AppNode
    }
}

// MARK: - NSOutlineViewDelegate

extension TreeView: NSOutlineViewDelegate {

    public func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return item is AppNode ? 28 : 24
    }

    public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        return false   // Don't use the grey group-row style; we style it ourselves
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let app = item as? AppNode {
            return makeAppRow(app)
        }
        if let win = item as? WindowInfo {
            return makeWindowRow(win)
        }
        return nil
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let win = windowInfo(atRow: outlineView.selectedRow) else { return }
        onWindowSelected?(win)
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        if let app = notification.userInfo?["NSObject"] as? AppNode {
            expandedPIDs.insert(app.id)
        }
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        if let app = notification.userInfo?["NSObject"] as? AppNode {
            expandedPIDs.remove(app.id)
        }
    }

    // MARK: Row view factories

    private func makeAppRow(_ app: AppNode) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // App icon
        let iconView = NSImageView()
        iconView.image = icon(for: app)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // App name label
        let nameLabel = NSTextField(labelWithString: app.name)
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        // Window count badge
        let badge = BadgeView(count: app.windows.count)
        badge.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(iconView)
        container.addSubview(nameLabel)
        container.addSubview(badge)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -4),

            badge.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        return container
    }

    private func makeWindowRow(_ win: WindowInfo) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // State indicator — SF Symbol icon with distinct color per state
        let indicator = NSImageView()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.imageScaling = .scaleProportionallyDown

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)

        switch win.state {
        case .normal:
            indicator.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Window")?
                .withSymbolConfiguration(symbolConfig)
            indicator.contentTintColor = dotColor(for: win)

        case .fullScreen:
            indicator.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Full Screen")?
                .withSymbolConfiguration(symbolConfig)
            indicator.contentTintColor = .systemCyan

        case .minimized:
            indicator.image = NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Minimized")?
                .withSymbolConfiguration(symbolConfig)
            indicator.contentTintColor = .systemYellow
        }

        // Window title label
        let titleLabel = NSTextField(labelWithString: win.title.isEmpty ? "(Untitled)" : win.title)
        titleLabel.font = NSFont.systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(indicator)
        container.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            indicator.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 14),
            indicator.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        return container
    }

    // MARK: Dot color palette

    private static let dotPalette: [NSColor] = [
        NSColor(red: 0.35, green: 0.70, blue: 1.00, alpha: 1),   // soft blue
        NSColor(red: 0.40, green: 0.85, blue: 0.55, alpha: 1),   // mint green
        NSColor(red: 1.00, green: 0.65, blue: 0.30, alpha: 1),   // warm orange
        NSColor(red: 0.85, green: 0.45, blue: 0.90, alpha: 1),   // lavender
        NSColor(red: 1.00, green: 0.45, blue: 0.45, alpha: 1),   // coral red
        NSColor(red: 0.40, green: 0.90, blue: 0.90, alpha: 1),   // teal
    ]

    private func dotColor(for win: WindowInfo) -> NSColor {
        let idx = Int(win.id) % Self.dotPalette.count
        return Self.dotPalette[idx]
    }
}

// MARK: - BadgeView

/// Small rounded rectangle showing a number — used for window counts in group rows.
private final class BadgeView: NSView {

    private let count: Int

    init(count: Int) {
        self.count = count
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var intrinsicContentSize: NSSize {
        let text = "\(count)"
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let width = max(textSize.width + 8, 16)
        return NSSize(width: width, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds
        let radius = bounds.height / 2

        let badgeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.25)
        badgeColor.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        path.fill()

        let text = "\(count)"
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let textOrigin = NSPoint(
            x: bounds.midX - textSize.width / 2,
            y: bounds.midY - textSize.height / 2
        )
        (text as NSString).draw(at: textOrigin, withAttributes: attrs)
    }
}

// MARK: - KeyableOutlineView

/// NSOutlineView subclass that intercepts the Enter/Return key and forwards it
/// to a closure, enabling keyboard-driven window activation.
private final class KeyableOutlineView: NSOutlineView {

    var onEnterKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // keyCode 36 = Return, keyCode 76 = numpad Enter
        if event.keyCode == 36 || event.keyCode == 76 {
            onEnterKey?()
        } else {
            super.keyDown(with: event)
        }
    }
}
