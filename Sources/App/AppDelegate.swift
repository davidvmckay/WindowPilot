import AppKit
import WindowPilotCore
import WindowPilotUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager!
    private var panel: PilotPanel!

    private let enumerator = WindowEnumerator()
    private let capture = WindowCapture()
    private let focuser = WindowFocuser()
    private let tracker = WindowActivityTracker()
    private let screenshotCache = ScreenshotCache()

    private var hasScreenRecording = false
    private var workspaceObserver: Any?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.checkAccessibility()
        hasScreenRecording = Permissions.checkScreenRecording()

        panel = PilotPanel()
        panel.updateScreenRecordingPermission(hasScreenRecording)
        wirePanel()
        startActivityTracking()

        hotkeyManager = HotkeyManager(onToggle: { [weak self] in
            self?.togglePanel()
        })

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

    // MARK: - Activity Tracking

    private func startActivityTracking() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
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

        // Get window title
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? appName

        tracker.windowDidFocus(
            windowID: windowID,
            pid: pid,
            appName: appName,
            bundleIdentifier: bundleID,
            windowTitle: title
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
        if windowInfo.state != .fullScreen,
           let _ = focuser.checkFullScreenBlock(targetWindowID: windowInfo.id) {
            // fullscreen→normal: try Ctrl+Arrow via Dock first (preserves fullscreen).
            // Falls back to exitCurrentFullScreen if Dock doesn't respond.
            if let nav = focuser.calculateSpaceNavigation(targetWindowID: windowInfo.id) {
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
                    if self.focuser.calculateSpaceNavigation(targetWindowID: windowInfo.id) != nil {
                        // Didn't switch — fall back to exit fullscreen
                        print("[WP] Ctrl+Arrow didn't work, falling back to exitCurrentFullScreen")
                        _ = self.focuser.exitCurrentFullScreen()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                            _ = self.focuser.focus(
                                pid: windowInfo.ownerPID,
                                windowID: windowInfo.id,
                                windowTitle: windowInfo.title,
                                state: windowInfo.state
                            )
                        }
                    } else {
                        // Worked! Focus the target window
                        print("[WP] Ctrl+Arrow switched Space successfully")
                        _ = self.focuser.focus(
                            pid: windowInfo.ownerPID,
                            windowID: windowInfo.id,
                            windowTitle: windowInfo.title,
                            state: windowInfo.state
                        )
                        self.focuser.raiseWindow(
                            pid: windowInfo.ownerPID,
                            windowID: windowInfo.id,
                            windowTitle: windowInfo.title
                        )
                    }
                }
            } else {
                // Can't calculate direction — use exit approach
                print("[WP] fullscreen→normal: exiting full-screen (no nav info)")
                _ = focuser.exitCurrentFullScreen()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    _ = self.focuser.focus(
                        pid: windowInfo.ownerPID,
                        windowID: windowInfo.id,
                        windowTitle: windowInfo.title,
                        state: windowInfo.state
                    )
                }
            }

        } else if windowInfo.state == .fullScreen {
            // normal→fullscreen: CGS switch first (so AX can see the window),
            // then immediately exit fullscreen. The window returns to a normal
            // Space with near-fullscreen size. No re-enter — avoids menu bar
            // residual that CGS-based fullscreen switching causes on macOS 16.
            print("[WP] normal→fullscreen: CGS switch then exit fullscreen")

            // Step 1: CGS switch to the fullscreen Space
            _ = focuser.focus(
                pid: windowInfo.ownerPID,
                windowID: windowInfo.id,
                windowTitle: windowInfo.title,
                state: windowInfo.state
            )

            // Step 2: Exit fullscreen immediately (AX can see it now)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                _ = self.focuser.exitCurrentFullScreen()
            }

            // Step 3: Focus the now-normal window
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                _ = self.focuser.focus(
                    pid: windowInfo.ownerPID,
                    windowID: windowInfo.id,
                    windowTitle: windowInfo.title,
                    state: .normal
                )
                self.focuser.raiseWindow(
                    pid: windowInfo.ownerPID,
                    windowID: windowInfo.id,
                    windowTitle: windowInfo.title
                )
            }

            // Step 4: Re-enter fullscreen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.focuser.reEnterFullScreen(
                    pid: windowInfo.ownerPID, windowID: windowInfo.id,
                    windowTitle: windowInfo.title
                )
            }

        } else {
            // normal→normal
            _ = focuser.focus(
                pid: windowInfo.ownerPID,
                windowID: windowInfo.id,
                windowTitle: windowInfo.title,
                state: windowInfo.state
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.focuser.raiseWindow(
                    pid: windowInfo.ownerPID,
                    windowID: windowInfo.id,
                    windowTitle: windowInfo.title
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
