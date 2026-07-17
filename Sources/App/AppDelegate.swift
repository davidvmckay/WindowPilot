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
    private var cachedApps: [AppNode] = []
    private var preferencesWindow: PreferencesWindow?
    private var navigatorMenuItem: NSMenuItem!
    private var carouselMenuItem: NSMenuItem!
    private var updateManager: UpdateManager!
    private var previewGeneration: UInt64 = 0

    // Sidebar mode (optional, off by default)
    private var sidebar: SidebarPanel?
    private var sidebarMenuItem: NSMenuItem!
    private var slotAllocator = SlotAllocator(capacity: 5)
    private lazy var pinStore: PinStore = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowPilot")
        return PinStore(capacity: 3, fileURL: dir.appendingPathComponent("pins.json"))
    }()
    private var previousFocusedWindowID: UInt32 = 0

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

        updateManager = UpdateManager()

        setupStatusItem()
        offerCLIInstallation()

        if UserDefaults.standard.bool(forKey: "SidebarEnabled") {
            enableSidebar()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let sidebar = self.sidebar else { return }
            sidebar.show(on: NSScreen.main)
        }

        // moveToActiveSpace strip stays behind on Space switch — reattach
        // (guarded inside: never un-hides over a fullscreen app).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.sidebar?.reattachToActiveSpace()
        }
    }

    // MARK: - CLI Installation

    private func offerCLIInstallation() {
        let cliDest = "/usr/local/bin/windowpilot-cli"

        // Skip if already installed
        if FileManager.default.fileExists(atPath: cliDest) { return }

        // Find CLI binary inside our app bundle
        guard let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("windowpilot-cli").path,
              FileManager.default.fileExists(atPath: bundlePath) else { return }

        let alert = NSAlert()
        alert.messageText = "Install Command-Line Tool?"
        alert.informativeText = "WindowPilot includes a CLI tool for switching windows from the terminal.\n\nInstall \"windowpilot-cli\" to /usr/local/bin?\n(Requires administrator password)"
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Skip")
        alert.alertStyle = .informational

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Use osascript with admin privileges to create a symlink
        let script = """
            do shell script "mkdir -p /usr/local/bin && ln -sf \\\"\(bundlePath)\\\" \\\"\(cliDest)\\\"" with administrator privileges
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error {
                let errAlert = NSAlert()
                errAlert.messageText = "CLI Installation Failed"
                errAlert.informativeText = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                errAlert.runModal()
            }
        }
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
        cachedApps = apps
        let liveIDs = Set(apps.flatMap { $0.windows.map { $0.id } })
        let recent = tracker.combinedRanking(limit: 20).filter { liveIDs.contains($0.id) }

        // Gather cached thumbnails for recent windows
        var thumbnails: [UInt32: CGImage] = [:]
        for w in recent {
            if let img = screenshotCache.image(forWindowID: w.id) {
                thumbnails[w.id] = img
            }
        }

        panel.show(apps: apps, recentWindows: recent, thumbnails: thumbnails)

        // Background refresh thumbnails for top 6 (skip minimized — use cached)
        if hasScreenRecording {
            let minimizedIDs = Set(apps.flatMap { $0.windows.filter { $0.state == .minimized }.map { $0.id } })
            let topIDs = Array(recent.prefix(6).map { $0.id }.filter { !minimizedIDs.contains($0) })
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
        let allLiveIDs = Set(allApps.flatMap { $0.windows.map { $0.id } })
        let mruWindows = tracker.combinedRanking(limit: 100).filter { allLiveIDs.contains($0.id) }
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

        // Remaining windows (not in MRU), filtered for transient windows
        for app in allApps {
            for window in app.windows {
                guard !mruIDs.contains(window.id) else { continue }
                guard !isTransientWindow(pid: window.ownerPID, windowID: window.id) else { continue }
                items.append(CarouselItem(
                    windowID: window.id, pid: window.ownerPID,
                    appName: app.name, windowTitle: window.title,
                    thumbnail: screenshotCache.image(forWindowID: window.id)
                ))
            }
        }

        guard !items.isEmpty else { return }

        // Show immediately with cached thumbnails/placeholders, then fill in
        // missing screenshots in the background (same pattern as showPanel).
        carousel.show(items: items)

        if hasScreenRecording {
            let minimizedIDs = Set(allApps.flatMap { $0.windows.filter { $0.state == .minimized }.map { $0.id } })
            let missingIDs = items
                .filter { $0.thumbnail == nil && !minimizedIDs.contains($0.windowID) }
                .map { $0.windowID }
            screenshotCache.refreshAsync(
                windowIDs: missingIDs,
                capture: { [weak self] wid in self?.capture.capture(windowID: wid) }
            ) { [weak self] refreshed in
                guard let self, self.carousel.isVisible else { return }
                self.carousel.updateThumbnails(refreshed)
            }
        }
    }

    private func wireCarousel() {
        carousel.onWindowActivated = { [weak self] windowInfo in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.performFocus(windowInfo)
            }
        }
    }

    // MARK: - Transient Window Detection

    /// Check if a window is transient (popup, notification, overlay).
    /// Uses AX: no close button or transient subrole.
    private func isTransientWindow(pid: Int32, windowID: UInt32) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return false }

        // Find the AX window matching this ID
        let getWindowFunc = unsafeBitCast(
            dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow"),
            to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self
        )
        for axWindow in axWindows {
            var wid: CGWindowID = 0
            guard getWindowFunc(axWindow, &wid) == .success, wid == windowID else { continue }

            // Check subrole
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef)
            let subrole = subroleRef as? String ?? ""
            if ["AXFloatingWindow", "AXSystemFloatingWindow", "AXSystemDialog"].contains(subrole) {
                return true
            }

            // No close button → transient
            var closeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &closeRef) != .success {
                return true
            }

            return false
        }
        return false
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
        previousFocusedWindowID = lastTrackedWindowID
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

        // 3. Small windows → transient (also captures bounds for the sidebar's
        //    per-display fullscreen check below)
        var focusedWindowBounds: CGRect = .zero
        if let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for info in windowList {
                guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                      wid == windowID,
                      let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                      let w = bounds["Width"], let h = bounds["Height"] else { continue }
                focusedWindowBounds = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: w, height: h)
                if !isTransient, w < 200 || h < 100 { isTransient = true }
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

        // Sidebar: re-sync slots, refresh the thumbnail of the window that
        // just lost focus (its content is "final" now), and auto-hide over
        // fullscreen on the strip's display.
        if let sidebar {
            syncSidebar()

            if hasScreenRecording, previousFocusedWindowID != 0 {
                let lostID = previousFocusedWindowID
                screenshotCache.refreshAsync(
                    windowIDs: [lostID],
                    capture: { [weak self] wid in self?.capture.capture(windowID: wid) }
                ) { [weak self] refreshed in
                    self?.sidebar?.updateThumbnails(refreshed)
                    self?.panel.updateRecentThumbnails(refreshed)
                }
            }

            // CG window bounds are top-left-origin; NSScreen frames are
            // bottom-left-origin — flip Y against the primary screen height
            // before intersecting.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let cocoaBounds = CGRect(
                x: focusedWindowBounds.minX,
                y: primaryHeight - focusedWindowBounds.maxY,
                width: focusedWindowBounds.width,
                height: focusedWindowBounds.height
            )
            let stripScreenFrame = (sidebar.currentScreen ?? NSScreen.main)?.frame ?? .zero
            let hideForFullscreen = isFullScreen && cocoaBounds.intersects(stripScreenFrame)
            sidebar.setHiddenForFullscreen(hideForFullscreen)
        }
    }

    // MARK: - Panel Wiring

    private func wirePanel() {
        panel.onWindowSelected = { [weak self] windowInfo in
            guard let self, self.hasScreenRecording else { return }
            self.previewGeneration &+= 1
            let generation = self.previewGeneration

            // Show the best image we already have; a fresh capture lands below.
            let cached = self.screenshotCache.image(forWindowID: windowInfo.id)
            self.panel.showPreview(image: cached)

            // Minimized windows produce tiny dock thumbnails — cached is all we have
            if windowInfo.state == .minimized { return }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let image = self.capture.capture(windowID: windowInfo.id)
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.previewGeneration else { return }
                    guard let image else { return }
                    // If the fresh capture is much smaller than cached, the window is
                    // likely mid-transition (resize/space switch) — keep the cached one.
                    if let cached, image.width * image.height < (cached.width * cached.height) / 2 {
                        return
                    }
                    self.panel.showPreview(image: image)
                    self.screenshotCache.cache(image: image, forWindowID: windowInfo.id)
                }
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
            if !self.focuser.close(pid: windowInfo.ownerPID, windowTitle: windowInfo.title) {
                ToastHUD.show("Couldn't close \"\(windowInfo.title)\"")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showPanel()
            }
        }

        panel.onWindowMinimize = { [weak self] windowInfo in
            guard let self else { return }
            if !self.focuser.minimize(pid: windowInfo.ownerPID, windowTitle: windowInfo.title) {
                ToastHUD.show("Couldn't minimize \"\(windowInfo.title)\"")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showPanel()
            }
        }

        panel.onSearchChanged = { [weak self] query in
            guard let self else { return }
            // Filter the snapshot from showPanel() — never re-enumerate per keystroke
            let filtered = SearchFilter.filter(self.cachedApps, query: query)
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
                            if !self.focuser.focus(
                                pid: info.ownerPID, windowID: info.id,
                                windowTitle: info.title, state: info.state
                            ) {
                                ToastHUD.show("Couldn't focus \"\(info.title)\" — it may have closed")
                            }
                        }
                    } else {
                        print("[WP] Ctrl+Arrow switched Space successfully")
                        if !self.focuser.focus(
                            pid: info.ownerPID, windowID: info.id,
                            windowTitle: info.title, state: info.state
                        ) {
                            ToastHUD.show("Couldn't focus \"\(info.title)\" — it may have closed")
                        }
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
                    if !self.focuser.focus(
                        pid: info.ownerPID, windowID: info.id,
                        windowTitle: info.title, state: info.state
                    ) {
                        ToastHUD.show("Couldn't focus \"\(info.title)\" — it may have closed")
                    }
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
                if !self.focuser.focus(
                    pid: info.ownerPID, windowID: info.id,
                    windowTitle: info.title, state: .normal
                ) {
                    ToastHUD.show("Couldn't focus \"\(info.title)\" — it may have closed")
                }
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
            if !focuser.focus(
                pid: info.ownerPID, windowID: info.id,
                windowTitle: info.title, state: info.state
            ) {
                ToastHUD.show("Couldn't focus \"\(info.title)\" — it may have closed")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.focuser.raiseWindow(
                    pid: info.ownerPID, windowID: info.id,
                    windowTitle: info.title
                )
            }
        }
    }

    // MARK: - Sidebar Mode

    @objc private func toggleSidebar() {
        let enabled = sidebar == nil
        UserDefaults.standard.set(enabled, forKey: "SidebarEnabled")
        sidebarMenuItem.state = enabled ? .on : .off
        if enabled { enableSidebar() } else { disableSidebar() }
    }

    private func enableSidebar() {
        guard sidebar == nil else { return }
        let panel = SidebarPanel()
        sidebar = panel

        panel.onWindowSelected = { [weak self] windowInfo in
            self?.performFocus(windowInfo)
        }
        panel.onDeadPinActivated = { [weak self] pinIndex in
            guard let self, let pin = self.pinStore.pins[safe: pinIndex] ?? nil,
                  let bundleID = pin.bundleIdentifier,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else {
                ToastHUD.show("Couldn't locate that app")
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
        panel.onPinRequested = { [weak self] windowInfo in
            guard let self else { return }
            let app = NSRunningApplication(processIdentifier: windowInfo.ownerPID)
            if self.pinStore.pinFirstFree(
                PinnedWindow(
                    bundleIdentifier: app?.bundleIdentifier,
                    appName: app?.localizedName ?? "",
                    title: windowInfo.title
                )
            ) == nil {
                ToastHUD.show("Pinned slots are full — unpin one first")
            }
            self.syncSidebar()
        }
        panel.onUnpinRequested = { [weak self] index in
            self?.pinStore.unpin(at: index)
            self?.syncSidebar()
        }
        panel.onWindowClosed = { [weak self] windowInfo in
            guard let self else { return }
            if !self.focuser.close(pid: windowInfo.ownerPID, windowTitle: windowInfo.title) {
                ToastHUD.show("Couldn't close \"\(windowInfo.title)\"")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.syncSidebar() }
        }
        panel.onWindowMinimized = { [weak self] windowInfo in
            guard let self else { return }
            if !self.focuser.minimize(pid: windowInfo.ownerPID, windowTitle: windowInfo.title) {
                ToastHUD.show("Couldn't minimize \"\(windowInfo.title)\"")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.syncSidebar() }
        }
        panel.onOverflowRequested = { [weak self] in
            self?.showPanel()
        }
        panel.onCollapseToggled = { collapsed in
            UserDefaults.standard.set(collapsed, forKey: "SidebarCollapsed")
        }

        panel.setCollapsed(UserDefaults.standard.bool(forKey: "SidebarCollapsed"))
        syncSidebar()
        panel.show(on: NSScreen.main)

        // Re-evaluate fullscreen suppression immediately — the tracker's
        // same-window guard would otherwise defer it to the next focus change
        // (e.g. enabling the sidebar while a fullscreen app is frontmost).
        lastTrackedWindowID = 0
        trackFocusedWindow()
    }

    private func disableSidebar() {
        sidebar?.hide()
        sidebar = nil
    }

    /// Rebuild sidebar slots from the current world. Called on focus changes
    /// (max every 2s via the tracker) and after pin/close/minimize actions.
    private func syncSidebar() {
        guard let sidebar else { return }
        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let apps = enumerator.enumerate(excludingPID: ownPID)

        // Pinned zone: resolve stored pins against live windows.
        var pinnedSlots: [SidebarSlot] = []
        var pinnedIDs = Set<UInt32>()
        for (i, pin) in pinStore.pins.enumerated() {
            guard let pin else {
                pinnedSlots.append(SidebarSlot(
                    kind: .pinned, index: i, window: nil, appName: "", pid: 0, thumbnail: nil
                ))
                continue
            }
            if let window = pinStore.resolve(pin, in: apps) {
                pinnedIDs.insert(window.id)
                pinnedSlots.append(SidebarSlot(
                    kind: .pinned, index: i, window: window, appName: pin.appName,
                    pid: window.ownerPID, thumbnail: screenshotCache.image(forWindowID: window.id)
                ))
            } else {
                pinnedSlots.append(SidebarSlot(
                    kind: .pinned, index: i, window: nil, appName: pin.appName,
                    pid: 0, thumbnail: nil, isDeadPin: true
                ))
            }
        }

        // Dynamic zone: parking-lot over everything not pinned.
        var infoByID: [UInt32: (WindowInfo, String)] = [:]
        for app in apps {
            for w in app.windows { infoByID[w.id] = (w, app.name) }
        }
        let live = Set(infoByID.keys).subtracting(pinnedIDs)
        let priority = tracker.combinedRanking(limit: 30).map(\.id).filter { !pinnedIDs.contains($0) }
        slotAllocator.sync(live: live, priority: priority)

        let dynamicSlots: [SidebarSlot] = slotAllocator.slots.enumerated().map { i, wid in
            guard let wid, let (window, appName) = infoByID[wid] else {
                return SidebarSlot(kind: .dynamic, index: i, window: nil, appName: "", pid: 0, thumbnail: nil)
            }
            return SidebarSlot(
                kind: .dynamic, index: i, window: window, appName: appName,
                pid: window.ownerPID, thumbnail: screenshotCache.image(forWindowID: window.id)
            )
        }

        sidebar.render(pinned: pinnedSlots, dynamic: dynamicSlots, focusedWindowID: lastTrackedWindowID)

        // Cold-start fill: capture screenshots for visible slots that have no
        // cached thumbnail yet (same pattern as the carousel). After the first
        // fill these are cache hits, so this is a no-op in steady state.
        if hasScreenRecording {
            let missingIDs = (pinnedSlots + dynamicSlots)
                .compactMap { slot -> UInt32? in
                    guard let window = slot.window,
                          slot.thumbnail == nil,
                          window.state != .minimized else { return nil }
                    return window.id
                }
            if !missingIDs.isEmpty {
                screenshotCache.refreshAsync(
                    windowIDs: missingIDs,
                    capture: { [weak self] wid in self?.capture.capture(windowID: wid) }
                ) { [weak self] refreshed in
                    self?.sidebar?.updateThumbnails(refreshed)
                }
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
        navigatorMenuItem = menu.addItem(
            withTitle: "Show Navigator (\(hotkeyManager.panelShortcutDisplay))",
            action: #selector(showAction), keyEquivalent: ""
        )
        carouselMenuItem = menu.addItem(
            withTitle: "Show Carousel (\(hotkeyManager.carouselShortcutDisplay))",
            action: #selector(carouselAction), keyEquivalent: ""
        )
        menu.addItem(.separator())
        sidebarMenuItem = menu.addItem(
            withTitle: "Show Sidebar",
            action: #selector(toggleSidebar), keyEquivalent: ""
        )
        sidebarMenuItem.state = UserDefaults.standard.bool(forKey: "SidebarEnabled") ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Change Shortcuts…", action: #selector(showPreferences), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "About WindowPilot", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quitAction), keyEquivalent: "q")

        for item in menu.items where item.action != nil {
            item.target = self
        }

        statusItem.menu = menu

        hotkeyManager.onShortcutsChanged = { [weak self] in
            self?.updateMenuShortcuts()
        }
    }

    private func updateMenuShortcuts() {
        navigatorMenuItem?.title = "Show Navigator (\(hotkeyManager.panelShortcutDisplay))"
        carouselMenuItem?.title = "Show Carousel (\(hotkeyManager.carouselShortcutDisplay))"
    }

    @objc private func showAction() {
        showPanel()
    }

    @objc private func carouselAction() {
        showCarousel()
    }

    @objc private func showPreferences() {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindow(hotkeyManager: hotkeyManager)
        }
        preferencesWindow?.showWindow()
    }

    @objc private func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? version

        let alert = NSAlert()
        alert.messageText = "WindowPilot"
        alert.informativeText = """
            Version \(version) (\(build))

            A macOS-native hotkey window navigator.
            See-and-pick your windows instantly.

            by Ethan Zhou
            © 2026 WindowPilot
            """
        alert.alertStyle = .informational

        if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
            alert.icon = icon
        }

        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func checkForUpdatesAction() {
        updateManager.checkForUpdates()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
