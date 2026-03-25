import AppKit
import WindowPilotCore
import WindowPilotUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager!
    private var panel: PilotPanel!
    private var carousel: CarouselPanel!

    private let enumerator = WindowEnumerator()
    private let capture = WindowCapture()
    private let focuser = WindowFocuser()
    private let tracker = WindowActivityTracker()
    private let screenshotCache = ScreenshotCache()

    private var hasScreenRecording = false
    private var workspaceObserver: Any?
    private var trackingTimer: Timer?
    private var lastTrackedWindowID: UInt32 = 0

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.checkAccessibility()
        hasScreenRecording = Permissions.checkScreenRecording()

        panel = PilotPanel()
        panel.updateScreenRecordingPermission(hasScreenRecording)
        wirePanel()

        carousel = CarouselPanel()
        wireCarousel()

        startActivityTracking()

        hotkeyManager = HotkeyManager(
            onToggle: { [weak self] in self?.togglePanel() },
            onCarousel: { [weak self] in self?.showCarousel() }
        )

        setupStatusItem()
    }

    // MARK: - Panel Toggle

    private func togglePanel() {
        if panel.isVisible {
            panel.dismiss()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        // Snapshot active window duration before reading data
        tracker.recordDuration()

        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let apps = enumerator.enumerate(excludingPID: ownPID)
        let recent = tracker.combinedRanking(limit: 20)

        // Gather cached thumbnails for recent windows
        var thumbnails: [UInt32: CGImage] = [:]
        for w in recent {
            if let img = screenshotCache.image(forWindowID: w.id) {
                thumbnails[w.id] = img
            }
        }

        panel.show(apps: apps, recentWindows: recent, thumbnails: thumbnails)

        // Background refresh thumbnails for top 6
        if hasScreenRecording {
            let topIDs = Array(recent.prefix(6).map { $0.id })
            screenshotCache.refreshAsync(
                windowIDs: topIDs,
                capture: { [weak self] wid in self?.capture.capture(windowID: wid) }
            ) { [weak self] refreshed in
                self?.panel.updateRecentThumbnails(refreshed)
            }
        }
    }

    // MARK: - Carousel

    private func showCarousel() {
        if carousel.isVisible {
            carousel.dismiss()
            return
        }
        // Dismiss panel if open
        if panel.isVisible { panel.dismiss() }

        tracker.recordDuration()

        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let allApps = enumerator.enumerate(excludingPID: ownPID)

        // Build carousel items: MRU first, then remaining windows
        let mruWindows = tracker.combinedRanking(limit: 100)
        let mruIDs = Set(mruWindows.map { $0.id })

        var items: [CarouselItem] = []

        // MRU windows first
        for tracked in mruWindows {
            items.append(CarouselItem(
                windowID: tracked.id, pid: tracked.pid,
                appName: tracked.appName, windowTitle: tracked.windowTitle,
                thumbnail: screenshotCache.image(forWindowID: tracked.id)
            ))
        }

        // Remaining windows (not in MRU)
        for app in allApps {
            for window in app.windows {
                guard !mruIDs.contains(window.id) else { continue }
                items.append(CarouselItem(
                    windowID: window.id, pid: window.ownerPID,
                    appName: app.name, windowTitle: window.title,
                    thumbnail: screenshotCache.image(forWindowID: window.id)
                ))
            }
        }

        guard !items.isEmpty else { return }

        // Capture screenshots for items that don't have cached thumbnails
        if hasScreenRecording {
            for i in items.indices {
                if items[i].thumbnail == nil {
                    if let img = capture.capture(windowID: items[i].windowID) {
                        screenshotCache.cache(image: img, forWindowID: items[i].windowID)
                        items[i] = CarouselItem(
                            windowID: items[i].windowID, pid: items[i].pid,
                            appName: items[i].appName, windowTitle: items[i].windowTitle,
                            thumbnail: img
                        )
                    }
                }
            }
        }

        carousel.show(items: items)
    }

    private func wireCarousel() {
        carousel.onWindowActivated = { [weak self] windowInfo in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.performFocus(windowInfo)
            }
        }
    }

    // MARK: - Activity Tracking

    private func startActivityTracking() {
        // Listen for app switches
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.trackFocusedWindow()
        }

        // Poll every 2s to catch window changes that don't trigger notifications:
        // - Same app, different window (e.g., clicking another Chrome window on monitor 2)
        // - Window focus changes within the same app
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.trackFocusedWindow()
        }

        // Track the currently focused window at launch
        trackFocusedWindow()
    }

    private func trackFocusedWindow() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier

        // Skip our own app
        if pid == Int32(ProcessInfo.processInfo.processIdentifier) { return }

        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier

        // Get the focused window via AX
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedWindow = focusedRef else { return }

        // Get window ID
        let axWindow = focusedWindow as! AXUIElement
        var windowID: CGWindowID = 0
        let getWindowFunc = unsafeBitCast(
            dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow"),
            to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self
        )
        guard getWindowFunc(axWindow, &windowID) == .success, windowID != 0 else { return }

        // Skip if same window is still focused (avoid redundant updates from timer)
        guard windowID != lastTrackedWindowID else { return }
        lastTrackedWindowID = windowID

        // Get window title
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? appName

        // Detect transient windows (popups, notifications, "Build Succeeded", etc.)
        var isTransient = false

        // 1. Check AX subrole
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String ?? ""
        let transientSubroles: Set<String> = [
            "AXFloatingWindow", "AXSystemFloatingWindow", "AXSystemDialog"
        ]
        if transientSubroles.contains(subrole) { isTransient = true }

        // 2. No close button → transient (popups, banners, notifications)
        if !isTransient {
            var closeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeRef) != .success {
                isTransient = true
            }
        }

        // 3. Small windows → transient
        if !isTransient,
           let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for info in windowList {
                guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                      wid == windowID,
                      let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                      let w = bounds["Width"], let h = bounds["Height"] else { continue }
                if w < 200 || h < 100 { isTransient = true }
                break
            }
        }

        // Check fullscreen state
        var fsRef: CFTypeRef?
        let isFullScreen = AXUIElementCopyAttributeValue(
            axWindow, "AXFullScreen" as CFString, &fsRef
        ) == .success && (fsRef as? Bool) == true

        tracker.windowDidFocus(
            windowID: windowID,
            pid: pid,
            appName: appName,
            bundleIdentifier: bundleID,
            windowTitle: title,
            isFullScreen: isFullScreen,
            isTransient: isTransient
        )
    }

    // MARK: - Panel Wiring

    private func wirePanel() {
        panel.onWindowSelected = { [weak self] windowInfo in
            guard let self, self.hasScreenRecording else { return }
            let image = self.capture.capture(windowID: windowInfo.id)
            self.panel.showPreview(image: image)
            // Cache for MRU thumbnails
            if let image {
                self.screenshotCache.cache(image: image, forWindowID: windowInfo.id)
            }
        }

        // Focus strategy (v6):
        //
        //   normal→fullscreen: simulated Ctrl+Arrow via Dock's native animation.
        //                      CGS bypasses menu bar update; only Dock handles it.
        //   normal→normal:     CGS + SkyLight + AX (direct Space switch)
        //   fullscreen→normal: AX exit full-screen on blocking window, wait for animation,
        //                      then CGS + SkyLight + AX to focus the target window.
        //
        panel.onWindowActivated = { [weak self] windowInfo in
            guard let self else { return }
            self.panel.dismiss()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.performFocus(windowInfo)
            }
        }

        panel.onWindowClose = { [weak self] windowInfo in
            guard let self else { return }
            _ = self.focuser.close(pid: windowInfo.ownerPID, windowTitle: windowInfo.title)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showPanel()
            }
        }

        panel.onWindowMinimize = { [weak self] windowInfo in
            guard let self else { return }
            _ = self.focuser.minimize(pid: windowInfo.ownerPID, windowTitle: windowInfo.title)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showPanel()
            }
        }

        panel.onSearchChanged = { [weak self] query in
            guard let self else { return }
            let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
            let allApps = self.enumerator.enumerate(excludingPID: ownPID)
            let filtered = SearchFilter.filter(allApps, query: query)
            self.panel.reloadTree(apps: filtered)
        }

        panel.onDismissRequested = { [weak self] in
            self?.panel.dismiss()
        }
    }

    // MARK: - Focus Logic

    private func performFocus(_ windowInfo: WindowInfo) {
        // Re-detect fullscreen state via CGS (tracker's isFullScreen can be stale)
        var state = windowInfo.state
        if state != .fullScreen && focuser.isWindowOnFullScreenSpace(windowID: windowInfo.id) {
            state = .fullScreen
            print("[WP] performFocus: CGS detected fullscreen for wid=\(windowInfo.id)")
        }
        let info = WindowInfo(
            id: windowInfo.id, ownerPID: windowInfo.ownerPID,
            title: windowInfo.title, bounds: windowInfo.bounds, state: state
        )

        if info.state != .fullScreen,
           let _ = focuser.checkFullScreenBlock(targetWindowID: info.id) {
            // fullscreen→normal: try Ctrl+Arrow via Dock first (preserves fullscreen).
            // Falls back to exitCurrentFullScreen if Dock doesn't respond.
            if let nav = focuser.calculateSpaceNavigation(targetWindowID: info.id) {
                print("[WP] fullscreen→normal: trying Ctrl+Arrow to Dock (preserving fullscreen)")

                let dockPID = NSRunningApplication.runningApplications(
                    withBundleIdentifier: "com.apple.dock"
                ).first?.processIdentifier

                for i in 0..<nav.count {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.7) {
                        self.focuser.simulateCtrlArrow(left: nav.left, dockPID: dockPID)
                    }
                }

                // Check if it worked after animation time
                let checkDelay = Double(nav.count) * 0.7 + 0.3
                DispatchQueue.main.asyncAfter(deadline: .now() + checkDelay) {
                    if self.focuser.calculateSpaceNavigation(targetWindowID: info.id) != nil {
                        print("[WP] Ctrl+Arrow didn't work, falling back to exitCurrentFullScreen")
                        _ = self.focuser.exitCurrentFullScreen()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                            _ = self.focuser.focus(
                                pid: info.ownerPID, windowID: info.id,
                                windowTitle: info.title, state: info.state
                            )
                        }
                    } else {
                        print("[WP] Ctrl+Arrow switched Space successfully")
                        _ = self.focuser.focus(
                            pid: info.ownerPID, windowID: info.id,
                            windowTitle: info.title, state: info.state
                        )
                        self.focuser.raiseWindow(
                            pid: info.ownerPID, windowID: info.id,
                            windowTitle: info.title
                        )
                    }
                }
            } else {
                // Can't calculate direction — use exit approach
                print("[WP] fullscreen→normal: exiting full-screen (no nav info)")
                _ = focuser.exitCurrentFullScreen()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    _ = self.focuser.focus(
                        pid: info.ownerPID, windowID: info.id,
                        windowTitle: info.title, state: info.state
                    )
                }
            }

        } else if info.state == .fullScreen {
            // normal→fullscreen: CGS switch → exit → focus → re-enter
            print("[WP] normal→fullscreen: CGS switch then exit fullscreen")

            _ = focuser.focus(
                pid: info.ownerPID, windowID: info.id,
                windowTitle: info.title, state: info.state
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                _ = self.focuser.exitCurrentFullScreen()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                _ = self.focuser.focus(
                    pid: info.ownerPID, windowID: info.id,
                    windowTitle: info.title, state: .normal
                )
                self.focuser.raiseWindow(
                    pid: info.ownerPID, windowID: info.id,
                    windowTitle: info.title
                )
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.focuser.reEnterFullScreen(
                    pid: info.ownerPID, windowID: info.id,
                    windowTitle: info.title
                )
            }

        } else {
            // normal→normal
            _ = focuser.focus(
                pid: info.ownerPID, windowID: info.id,
                windowTitle: info.title, state: info.state
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.focuser.raiseWindow(
                    pid: info.ownerPID, windowID: info.id,
                    windowTitle: info.title
                )
            }
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "WindowPilot")
                ?? NSImage(named: NSImage.applicationIconName)
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Show WindowPilot (⌥Space)", action: #selector(showAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quitAction), keyEquivalent: "q")

        for item in menu.items where item.action != nil {
            item.target = self
        }

        statusItem.menu = menu
    }

    @objc private func showAction() {
        showPanel()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}
