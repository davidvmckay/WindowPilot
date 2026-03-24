import ApplicationServices
import Foundation

// MARK: - Private APIs

// SkyLight: process/window focus
@_silgen_name("_SLPSSetFrontProcessWithOptions") @discardableResult
private func _SLPSSetFrontProcessWithOptions(
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ wid: CGWindowID, _ mode: UInt32
) -> CGError

@_silgen_name("SLPSPostEventRecordTo") @discardableResult
private func SLPSPostEventRecordTo(
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ bytes: UnsafeMutablePointer<UInt8>
) -> CGError

@_silgen_name("GetProcessForPID") @discardableResult
private func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

// CGS: direct Space switching (for when SkyLight alone doesn't trigger Space switch)
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> UInt32

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: UInt32, _ mask: Int, _ wids: CFArray) -> CFArray?

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: UInt32) -> CFArray?

@_silgen_name("CGSManagedDisplaySetCurrentSpace")
private func CGSManagedDisplaySetCurrentSpace(_ cid: UInt32, _ display: CFString, _ space: UInt64)

@_silgen_name("CGSMoveWindowsToManagedSpace")
private func CGSMoveWindowsToManagedSpace(_ cid: UInt32, _ windows: CFArray, _ space: UInt64)

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: UInt32) -> UInt64

@_silgen_name("CGSSpaceGetType")
private func CGSSpaceGetType(_ cid: UInt32, _ sid: UInt64) -> Int
// CGSSpaceType: 0 = user, 4 = fullscreen

// MARK: - Protocol

public protocol WindowFocusing {
    func focus(pid: Int32, windowID: UInt32, windowTitle: String, state: WindowState) -> Bool
    func hasAccessibilityPermission() -> Bool
}

extension WindowFocusing {
    public func focus(pid: Int32, windowTitle: String) -> Bool {
        focus(pid: pid, windowID: 0, windowTitle: windowTitle, state: .normal)
    }

    public func focus(pid: Int32, windowTitle: String, state: WindowState) -> Bool {
        focus(pid: pid, windowID: 0, windowTitle: windowTitle, state: state)
    }
}

// MARK: - Implementation

public final class WindowFocuser: WindowFocusing {

    public init() {}

    public func focus(pid: Int32, windowID: UInt32, windowTitle: String, state: WindowState) -> Bool {
        guard hasAccessibilityPermission() else { return false }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let axResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        let windows = (axResult == .success) ? (windowsRef as? [AXUIElement] ?? []) : []

        // Match by CGWindowID first (reliable), fall back to title match
        let axWindow = findWindowByID(windowID, in: windows)
            ?? findWindow(matching: windowTitle, in: windows)
            ?? windows.first

        print("[WP] focus: pid=\(pid) wid=\(windowID) state=\(state) axMatch=\(axWindow != nil)")

        // Unminimize before focus
        if state == .minimized, let axWindow {
            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        }

        if state == .fullScreen {
            // Entering a full-screen Space: CGS → SkyLight → AX.
            // All three layers are needed for the system to fully update
            // (Space switch + front process + menu bar).
            if windowID != 0 {
                switchDisplayToWindowSpace(windowID: windowID)
                var psn = ProcessSerialNumber()
                GetProcessForPID(pid, &psn)
                _SLPSSetFrontProcessWithOptions(&psn, windowID, 0x200)
                makeKeyWindow(&psn, windowID: windowID)
            }
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, true as CFTypeRef)
            if let axWindow {
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            }
        } else {
            // Non-full-screen target: AppDelegate calls activate() first to exit
            // any current full-screen Space, then calls focus() again. On the
            // second call, CGS switches to the correct Space (activate may have
            // landed on the wrong one if the app has multiple Spaces).
            if windowID != 0 {
                switchDisplayToWindowSpace(windowID: windowID)
                var psn = ProcessSerialNumber()
                GetProcessForPID(pid, &psn)
                _SLPSSetFrontProcessWithOptions(&psn, windowID, 0x200)
                makeKeyWindow(&psn, windowID: windowID)
            }
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, true as CFTypeRef)
            if let axWindow {
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            }
        }

        return true
    }

    public func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Window actions

    /// Minimize a window via AX. Returns true on success.
    public func minimize(pid: Int32, windowTitle: String) -> Bool {
        guard hasAccessibilityPermission() else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let window = findWindow(matching: windowTitle, in: windows) else { return false }
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef) == .success
    }

    /// Close a window via AX. Returns true on success.
    public func close(pid: Int32, windowTitle: String) -> Bool {
        guard hasAccessibilityPermission() else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let window = findWindow(matching: windowTitle, in: windows) else { return false }
        // Find the close button and press it
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &buttonRef) == .success,
              let closeButton = buttonRef as! AXUIElement? else { return false }
        return AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success
    }

    // MARK: - Full-screen Space exit

    /// Result of checking if a full-screen Space blocks the target window.
    public struct FullScreenBlockInfo {
        public let arrowPresses: [(left: Bool, count: Int)]  // direction + how many presses
    }

    /// Check if the target window's display is blocked by a full-screen Space.
    /// If blocked, returns direction info for Ctrl+Arrow simulation.
    public func checkFullScreenBlock(targetWindowID: UInt32) -> FullScreenBlockInfo? {
        let cid = CGSMainConnectionID()

        guard let targetSpacesCF = CGSCopySpacesForWindows(cid, 0x7, [targetWindowID as NSNumber] as CFArray),
              let targetSpaceIDs = targetSpacesCF as? [UInt64],
              let targetSpaceID = targetSpaceIDs.first,
              let displaySpacesCF = CGSCopyManagedDisplaySpaces(cid),
              let displaySpaces = displaySpacesCF as? [[String: Any]] else { return nil }

        for displayInfo in displaySpaces {
            let spaces = displayInfo["Spaces"] as? [[String: Any]] ?? []
            let spaceIDs = spaces.compactMap { $0["id64"] as? UInt64 }

            guard spaceIDs.contains(targetSpaceID) else { continue }
            guard let currentSpaceInfo = displayInfo["Current Space"] as? [String: Any],
                  let currentSpaceID = currentSpaceInfo["id64"] as? UInt64,
                  currentSpaceID != targetSpaceID else { return nil }

            // Check if current Space is full-screen
            guard CGSSpaceGetType(cid, currentSpaceID) == 4 else { return nil }

            // Find indices in the Space list to determine direction
            guard let currentIdx = spaceIDs.firstIndex(of: currentSpaceID),
                  let targetIdx = spaceIDs.firstIndex(of: targetSpaceID) else { return nil }

            let distance = targetIdx - currentIdx  // negative = left, positive = right
            let left = distance < 0
            let count = abs(distance)

            print("[WP] fullscreen blocked: current=\(currentSpaceID) idx=\(currentIdx) target=\(targetSpaceID) idx=\(targetIdx) → \(count)x Ctrl+\(left ? "Left" : "Right")")
            return FullScreenBlockInfo(arrowPresses: [(left: left, count: count)])
        }
        return nil
    }

    /// Calculate direction and count of Ctrl+Arrow presses needed to reach
    /// the target window's Space from the current Space. Works for any
    /// Space type combination (normal↔normal, normal↔fullscreen).
    public struct SpaceNavigation {
        public let left: Bool
        public let count: Int
    }

    public func calculateSpaceNavigation(targetWindowID: UInt32) -> SpaceNavigation? {
        let cid = CGSMainConnectionID()

        guard let targetSpacesCF = CGSCopySpacesForWindows(cid, 0x7, [targetWindowID as NSNumber] as CFArray),
              let targetSpaceIDs = targetSpacesCF as? [UInt64],
              let targetSpaceID = targetSpaceIDs.first,
              let displaySpacesCF = CGSCopyManagedDisplaySpaces(cid),
              let displaySpaces = displaySpacesCF as? [[String: Any]] else { return nil }

        for displayInfo in displaySpaces {
            let spaces = displayInfo["Spaces"] as? [[String: Any]] ?? []
            let spaceIDs = spaces.compactMap { $0["id64"] as? UInt64 }

            guard spaceIDs.contains(targetSpaceID),
                  let currentSpaceInfo = displayInfo["Current Space"] as? [String: Any],
                  let currentSpaceID = currentSpaceInfo["id64"] as? UInt64,
                  currentSpaceID != targetSpaceID,
                  let currentIdx = spaceIDs.firstIndex(of: currentSpaceID),
                  let targetIdx = spaceIDs.firstIndex(of: targetSpaceID) else { continue }

            let distance = Int(targetIdx) - Int(currentIdx)
            print("[WP] spaceNav: current idx=\(currentIdx) target idx=\(targetIdx) → \(abs(distance))x Ctrl+\(distance < 0 ? "Left" : "Right")")
            return SpaceNavigation(left: distance < 0, count: abs(distance))
        }
        return nil
    }

    /// Simulate Ctrl+Arrow key press to switch Spaces via Dock's native animation.
    ///
    /// Posts the event directly to the Dock process via CGEventPostToPid.
    /// This bypasses the normal event routing — the Dock receives the event
    /// directly rather than intercepting it from the HID stream.
    public func simulateCtrlArrow(left: Bool, dockPID: pid_t? = nil) {
        let keyCode: CGKeyCode = left ? 123 : 124  // 123=Left, 124=Right

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            print("[WP] simulateCtrlArrow: failed to create CGEvent")
            return
        }
        keyDown.flags = .maskControl
        keyUp.flags = .maskControl

        if let dockPID {
            // Post directly to the Dock process
            keyDown.postToPid(dockPID)
            usleep(80_000)
            keyUp.postToPid(dockPID)
            print("[WP] simulated Ctrl+\(left ? "Left" : "Right") via CGEventPostToPid(Dock:\(dockPID))")
        } else {
            // Fallback: broadcast via HID tap
            keyDown.post(tap: .cghidEventTap)
            usleep(80_000)
            keyUp.post(tap: .cghidEventTap)
            print("[WP] simulated Ctrl+\(left ? "Left" : "Right") via cghidEventTap")
        }
    }

    /// Pure AX raise — ONLY raises the specific window, nothing else.
    /// No CGS, no SkyLight, no kAXFrontmostAttribute.
    /// Used after activate() has already triggered the Space switch.
    public func raiseWindow(pid: Int32, windowID: UInt32, windowTitle: String) {
        guard hasAccessibilityPermission() else { return }
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        let windows = (result == .success) ? (windowsRef as? [AXUIElement] ?? []) : []
        if let axWindow = findWindowByID(windowID, in: windows)
            ?? findWindow(matching: windowTitle, in: windows)
            ?? windows.first {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        }
    }

    /// Light focus: CGS Space switch + AX raise ONLY.
    /// No SkyLight, no kAXFrontmostAttribute — those cause the window to appear
    /// as an overlay on full-screen instead of properly switching Spaces.
    public func focusLight(pid: Int32, windowID: UInt32, windowTitle: String) {
        guard hasAccessibilityPermission() else { return }
        print("[WP] focusLight: pid=\(pid) wid=\(windowID)")
        if windowID != 0 {
            switchDisplayToWindowSpace(windowID: windowID)
        }
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        let windows = (result == .success) ? (windowsRef as? [AXUIElement] ?? []) : []
        if let axWindow = findWindowByID(windowID, in: windows)
            ?? findWindow(matching: windowTitle, in: windows)
            ?? windows.first {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        }
    }

    /// Info about a window that was exited from full-screen.
    public struct ExitedFullScreenInfo {
        public let pid: Int32
        public let windowID: UInt32
        public let windowTitle: String
    }

    /// Exit the full-screen window blocking the current display.
    /// Returns info about the exited window (for later re-entering full-screen).
    public func exitCurrentFullScreen() -> ExitedFullScreenInfo? {
        guard hasAccessibilityPermission() else { return nil }
        let cid = CGSMainConnectionID()

        guard let displaySpacesCF = CGSCopyManagedDisplaySpaces(cid),
              let displaySpaces = displaySpacesCF as? [[String: Any]] else { return nil }

        for displayInfo in displaySpaces {
            guard let currentSpaceInfo = displayInfo["Current Space"] as? [String: Any],
                  let currentSpaceID = currentSpaceInfo["id64"] as? UInt64,
                  CGSSpaceGetType(cid, currentSpaceID) == 4 else { continue }

            // This display's current Space is full-screen. Find the window on it.
            guard let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else { continue }

            for winInfo in windowList {
                guard let windowID = winInfo[kCGWindowNumber as String] as? CGWindowID,
                      let pid = winInfo[kCGWindowOwnerPID as String] as? pid_t,
                      let layer = winInfo[kCGWindowLayer as String] as? Int,
                      layer == 0 else { continue }

                // Confirm this window is on the full-screen Space
                guard let spacesCF = CGSCopySpacesForWindows(
                    cid, 0x7, [windowID as NSNumber] as CFArray
                ),
                let spaceIDs = spacesCF as? [UInt64],
                spaceIDs.contains(currentSpaceID) else { continue }

                // Un-fullscreen via AX
                let appElement = AXUIElementCreateApplication(pid)
                var windowsRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    appElement, kAXWindowsAttribute as CFString, &windowsRef
                ) == .success,
                let axWindows = windowsRef as? [AXUIElement] else { continue }

                if let axWindow = findWindowByID(windowID, in: axWindows) {
                    print("[WP] exitCurrentFullScreen: pid=\(pid) wid=\(windowID)")

                    // Before exiting full-screen, set the window's position/size
                    // to near-fullscreen so it doesn't shrink to a small size.
                    // Get the display's visible frame (excludes menu bar and Dock).
                    if displayInfo["Display Identifier"] is String {
                        // Use CGWindowList to get the screen size from the window's bounds
                        if let bounds = winInfo[kCGWindowBounds as String] as? [String: CGFloat],
                           let screenW = bounds["Width"],
                           let screenH = bounds["Height"] {
                            // Set AXPosition and AXSize to near-fullscreen
                            // Leave 10px margin so it's clearly not full-screen
                            var position = CGPoint(x: 5, y: 30)  // below menu bar
                            var size = CGSize(width: screenW - 10, height: screenH - 10)
                            if let posValue = AXValueCreate(.cgPoint, &position) {
                                AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
                            }
                            if let sizeValue = AXValueCreate(.cgSize, &size) {
                                AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
                            }
                            print("[WP] set window size to \(size.width)x\(size.height)")
                        }
                    }

                    AXUIElementSetAttributeValue(
                        axWindow, "AXFullScreen" as CFString, false as CFTypeRef
                    )
                    let title = (winInfo[kCGWindowName as String] as? String)
                        ?? (winInfo[kCGWindowOwnerName as String] as? String)
                        ?? ""
                    return ExitedFullScreenInfo(
                        pid: pid, windowID: windowID, windowTitle: title
                    )
                }
            }
        }
        return nil
    }

    /// Exit a specific window's full-screen mode, setting its size to near-fullscreen
    /// so it doesn't shrink to a small window. Returns true on success.
    public func exitFullScreen(pid: Int32, windowID: UInt32, windowTitle: String) -> Bool {
        guard hasAccessibilityPermission() else { return false }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            print("[WP] exitFullScreen: failed to get AX windows for pid=\(pid)")
            return false
        }

        // Debug: log all AX windows to understand what's available
        for (i, w) in axWindows.enumerated() {
            var wid: CGWindowID = 0
            Self._AXUIElementGetWindow(w, &wid)
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef)
            var fsRef: CFTypeRef?
            let fsErr = AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &fsRef)
            print("[WP] exitFS: [\(i)] wid=\(wid) title=\"\(titleRef as? String ?? "?")\" fs=\(fsRef ?? "nil" as CFTypeRef) err=\(fsErr.rawValue)")
        }

        // Try multiple strategies to find the target window:
        // 1. By CGWindowID (fails on other Spaces on macOS 16)
        // 2. By AXFullScreen = true
        // 3. By title match
        // 4. First window (last resort)
        var axWindow: AXUIElement? = findWindowByID(windowID, in: axWindows)

        if axWindow == nil {
            for w in axWindows {
                var fsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &fsRef) == .success,
                   (fsRef as? Bool) == true {
                    axWindow = w
                    print("[WP] exitFS: matched by AXFullScreen=true")
                    break
                }
            }
        }

        if axWindow == nil {
            axWindow = findWindow(matching: windowTitle, in: axWindows)
            if axWindow != nil {
                print("[WP] exitFS: matched by title \"\(windowTitle)\"")
            }
        }

        if axWindow == nil, let first = axWindows.first {
            axWindow = first
            print("[WP] exitFS: using first window (last resort)")
        }

        guard let axWindow else {
            print("[WP] exitFullScreen: no windows at all for pid=\(pid)")
            return false
        }

        // Get screen size from CGWindowList for near-fullscreen sizing
        if let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for winInfo in windowList {
                guard let wid = winInfo[kCGWindowNumber as String] as? CGWindowID,
                      wid == windowID,
                      let bounds = winInfo[kCGWindowBounds as String] as? [String: CGFloat],
                      let w = bounds["Width"], let h = bounds["Height"] else { continue }

                var position = CGPoint(x: 5, y: 30)
                var size = CGSize(width: w - 10, height: h - 40)
                if let posValue = AXValueCreate(.cgPoint, &position) {
                    AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
                }
                if let sizeValue = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
                }
                print("[WP] exitFullScreen: set size \(size.width)x\(size.height)")
                break
            }
        }

        print("[WP] exitFullScreen: pid=\(pid) wid=\(windowID)")
        AXUIElementSetAttributeValue(axWindow, "AXFullScreen" as CFString, false as CFTypeRef)
        return true
    }

    /// Re-enter full-screen for a previously exited window.
    public func reEnterFullScreen(pid: Int32, windowID: UInt32, windowTitle: String) {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            print("[WP] reEnterFullScreen: failed to get AX windows")
            return
        }

        // findWindowByID can fail after fullscreen exit (ID may change)
        let window = findWindowByID(windowID, in: windows)
            ?? findWindow(matching: windowTitle, in: windows)
            ?? windows.first

        guard let window else {
            print("[WP] reEnterFullScreen: no window found")
            return
        }
        print("[WP] re-entering full-screen: pid=\(pid) wid=\(windowID)")
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, true as CFTypeRef)
    }

    // MARK: - CGS Space switching

    /// Find which Space the window is on and switch that display to it.
    /// This handles full-screen windows on other monitors where activate() fails.
    private func switchDisplayToWindowSpace(windowID: CGWindowID) {
        let cid = CGSMainConnectionID()

        // Find which Space(s) the window is on
        guard let spacesCF = CGSCopySpacesForWindows(cid, 0x7, [windowID as NSNumber] as CFArray),
              let spaceIDs = spacesCF as? [UInt64],
              let targetSpaceID = spaceIDs.first else {
            print("[WP] CGSCopySpacesForWindows: no spaces for wid=\(windowID)")
            return
        }
        print("[WP] window \(windowID) is on space \(targetSpaceID)")

        // Check if this Space is already the active Space on its display
        let currentSpace = CGSGetActiveSpace(cid)
        if targetSpaceID == currentSpace {
            print("[WP] already on target space")
            return
        }

        // Find which display owns this Space
        guard let displaySpacesCF = CGSCopyManagedDisplaySpaces(cid),
              let displaySpaces = displaySpacesCF as? [[String: Any]] else {
            print("[WP] CGSCopyManagedDisplaySpaces: failed")
            return
        }

        for displayInfo in displaySpaces {
            guard let displayUUID = displayInfo["Display Identifier"] as? String,
                  let spaces = displayInfo["Spaces"] as? [[String: Any]] else { continue }

            // Check if the current Space of this display is already the target
            if let currentSpaceInfo = displayInfo["Current Space"] as? [String: Any],
               let displayCurrentSpaceID = currentSpaceInfo["id64"] as? UInt64,
               displayCurrentSpaceID == targetSpaceID {
                print("[WP] display '\(displayUUID)' already on space \(targetSpaceID)")
                return
            }

            for space in spaces {
                guard let spaceID = space["id64"] as? UInt64 else { continue }
                if spaceID == targetSpaceID {
                    print("[WP] switching display '\(displayUUID)' to space \(targetSpaceID)")
                    CGSManagedDisplaySetCurrentSpace(cid, displayUUID as CFString, targetSpaceID)
                    return
                }
            }
        }
        print("[WP] space \(targetSpaceID) not found on any display")
    }

    // MARK: - SkyLight makeKeyWindow

    private func makeKeyWindow(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, windowID: UInt32) {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        var wid = windowID
        memcpy(&bytes[0x3c], &wid, MemoryLayout<UInt32>.size)
        memset(&bytes[0x20], 0xff, 0x10)
        bytes[0x08] = 0x01
        SLPSPostEventRecordTo(psn, &bytes)
        bytes[0x08] = 0x02
        SLPSPostEventRecordTo(psn, &bytes)
    }

    // MARK: - AX helpers

    @_silgen_name("_AXUIElementGetWindow") @discardableResult
    private static func _AXUIElementGetWindow(_ el: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

    /// Match AX window by CGWindowID — reliable even when multiple windows share titles.
    private func findWindowByID(_ targetID: UInt32, in windows: [AXUIElement]) -> AXUIElement? {
        guard targetID != 0 else { return nil }
        for window in windows {
            var wid: CGWindowID = 0
            if Self._AXUIElementGetWindow(window, &wid) == .success, wid == targetID {
                return window
            }
        }
        return nil
    }

    private func findWindow(matching title: String, in windows: [AXUIElement]) -> AXUIElement? {
        for window in windows {
            if let axTitle = getTitle(of: window), axTitle == title {
                return window
            }
        }
        if title == "Untitled" && !windows.isEmpty {
            return windows[0]
        }
        for window in windows {
            if let axTitle = getTitle(of: window) {
                if axTitle.contains(title) || title.contains(axTitle) {
                    return window
                }
            }
        }
        for window in windows {
            var fsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fsRef) == .success,
               (fsRef as? Bool) == true {
                return window
            }
        }
        return nil
    }

    private func getTitle(of window: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        guard result == .success, let title = titleRef as? String else { return nil }
        return title
    }
}
