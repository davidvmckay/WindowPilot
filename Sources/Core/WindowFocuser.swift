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

    // MARK: - Target resolution (pure decision)

    /// How aggressively a window may be resolved when the exact target is not
    /// found by CGWindowID.
    enum WindowMatchPolicy {
        /// Focus/raise: an ID match wins; a title match is an acceptable
        /// fallback (covers AX enumeration hiccups) even when an ID was given.
        /// Non-destructive, so a single title match is enough.
        case focus
        /// Minimize/close: destructive. When an ID is given it must resolve
        /// exactly — never fall back to title or the first window. Title-only
        /// resolution is allowed solely when no ID was given AND the title is
        /// unambiguous (exactly one window matches).
        case destructive
    }

    enum WindowResolution: Equatable {
        case matched
        case failed
    }

    /// Pure matched/failed decision — no AX access, unit-testable in isolation.
    /// `idMatchFound`: an AX window matched the requested CGWindowID.
    /// `titleMatchCount`: how many windows matched the requested title.
    static func resolution(
        policy: WindowMatchPolicy,
        windowID: UInt32,
        idMatchFound: Bool,
        titleMatchCount: Int
    ) -> WindowResolution {
        switch policy {
        case .focus:
            // ID first; any title match is an acceptable fallback.
            return (idMatchFound || titleMatchCount >= 1) ? .matched : .failed
        case .destructive:
            if windowID != 0 {
                // Exact ID required — never fall back to title or first window.
                return idMatchFound ? .matched : .failed
            }
            // Title-only: act solely when the title is unambiguous.
            return titleMatchCount == 1 ? .matched : .failed
        }
    }

    public func focus(pid: Int32, windowID: UInt32, windowTitle: String, state: WindowState) -> Bool {
        guard hasAccessibilityPermission() else { return false }

        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let axResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        let windows = (axResult == .success) ? (windowsRef as? [AXUIElement] ?? []) : []

        // Match by CGWindowID first (reliable), fall back to title match.
        // No windows.first tail: an unresolved target must fail (return false)
        // rather than silently raising the app's first window.
        let byID = findWindowByID(windowID, in: windows)
        let byTitle = (byID == nil) ? findWindow(matching: windowTitle, in: windows) : nil
        let axWindow: AXUIElement? = Self.resolution(
            policy: .focus, windowID: windowID,
            idMatchFound: byID != nil, titleMatchCount: byTitle != nil ? 1 : 0
        ) == .matched ? (byID ?? byTitle) : nil

        print("[WP] focus: pid=\(pid) wid=\(windowID) state=\(state) axMatch=\(axWindow != nil)")

        // Unminimize before focus
        if state == .minimized, let axWindow {
            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        }

        // CGS → SkyLight → AX. All three layers are needed for the system to
        // fully update (Space switch + front process + menu bar). Same sequence
        // for full-screen and normal targets.
        if windowID != 0 {
            switchDisplayToWindowSpace(windowID: windowID)
            var psn = ProcessSerialNumber()
            GetProcessForPID(pid, &psn)
            _SLPSSetFrontProcessWithOptions(&psn, windowID, 0x200)
            makeKeyWindow(&psn, windowID: windowID)
        }
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, true as CFTypeRef)

        guard let axWindow else {
            print("[WP] focus: no AX window match for wid=\(windowID) '\(windowTitle)'")
            return false
        }
        let raiseResult = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        if raiseResult != .success {
            print("[WP] focus: AXRaise failed (\(raiseResult.rawValue)) for wid=\(windowID)")
        }
        return raiseResult == .success
    }

    public func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Window actions

    /// Minimize a window via AX. Returns true on success.
    /// Destructive: resolves the exact window by CGWindowID (no fallback when
    /// an ID is given); see `resolveDestructiveTarget`.
    public func minimize(pid: Int32, windowID: UInt32, windowTitle: String) -> Bool {
        guard hasAccessibilityPermission() else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let window = resolveDestructiveTarget(windowID: windowID, windowTitle: windowTitle, in: windows)
        else { return false }
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef) == .success
    }

    /// Close a window via AX. Returns true on success.
    /// Destructive: resolves the exact window by CGWindowID (no fallback when
    /// an ID is given); see `resolveDestructiveTarget`.
    public func close(pid: Int32, windowID: UInt32, windowTitle: String) -> Bool {
        guard hasAccessibilityPermission() else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let window = resolveDestructiveTarget(windowID: windowID, windowTitle: windowTitle, in: windows)
        else { return false }
        // Find the close button and press it
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &buttonRef) == .success,
              let closeButton = buttonRef as! AXUIElement? else { return false }
        return AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success
    }

    /// Resolve the exact window for a destructive op. Delegates the safe/unsafe
    /// decision to the pure `resolution(policy: .destructive, …)` helper: an
    /// explicit windowID must match by CGWindowID (never a title or first-window
    /// fallback); a title is honoured only when no ID was given AND it is
    /// unambiguous (exactly one exact-title match).
    private func resolveDestructiveTarget(
        windowID: UInt32, windowTitle: String, in windows: [AXUIElement]
    ) -> AXUIElement? {
        let byID = findWindowByID(windowID, in: windows)
        let titleMatches = windows.filter { getTitle(of: $0) == windowTitle }
        switch Self.resolution(
            policy: .destructive, windowID: windowID,
            idMatchFound: byID != nil, titleMatchCount: titleMatches.count
        ) {
        case .failed:
            return nil
        case .matched:
            return byID ?? titleMatches.first
        }
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

    /// Check if a window is on a full-screen Space (CGSSpaceType == 4).
    /// Uses CGS to check in real-time — more reliable than cached AX state.
    public func isWindowOnFullScreenSpace(windowID: UInt32) -> Bool {
        let cid = CGSMainConnectionID()
        guard let spacesCF = CGSCopySpacesForWindows(cid, 0x7, [windowID as NSNumber] as CFArray),
              let spaceIDs = spacesCF as? [UInt64],
              let spaceID = spaceIDs.first else { return false }
        return CGSSpaceGetType(cid, spaceID) == 4
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
    ///
    /// No windows.first tail: if the exact target (by ID, then title fallback)
    /// can't be resolved — e.g. it closed between focus() and this call — do
    /// nothing rather than raising a different window of the same app. Routes
    /// the same matched/failed decision as focus() through the pure
    /// `resolution(policy: .focus, …)` helper.
    public func raiseWindow(pid: Int32, windowID: UInt32, windowTitle: String) {
        guard hasAccessibilityPermission() else { return }
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        let windows = (result == .success) ? (windowsRef as? [AXUIElement] ?? []) : []

        let byID = findWindowByID(windowID, in: windows)
        let byTitle = (byID == nil) ? findWindow(matching: windowTitle, in: windows) : nil
        let axWindow: AXUIElement? = Self.resolution(
            policy: .focus, windowID: windowID,
            idMatchFound: byID != nil, titleMatchCount: byTitle != nil ? 1 : 0
        ) == .matched ? (byID ?? byTitle) : nil

        guard let axWindow else { return }
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
    }

    /// Info about a window that was exited from full-screen.
    public struct ExitedFullScreenInfo {
        public let pid: Int32
        public let windowID: UInt32
        public let windowTitle: String
    }

    /// One display's Space membership, as needed to decide which full-screen
    /// Space to exit. Pure value type — no CGS/AX handles.
    struct DisplaySpaceInfo {
        let index: Int                       // position in CGSCopyManagedDisplaySpaces
        let spaceIDs: [UInt64]               // all Spaces belonging to this display
        let currentSpaceIsFullScreen: Bool   // is its *current* Space full-screen?
    }

    /// Pure decision: which display's full-screen Space should `exitCurrentFullScreen`
    /// exit. Among displays whose current Space is full-screen, prefer the one
    /// whose Space list contains one of the target window's Spaces; otherwise
    /// fall back to the first full-screen display (the historic behaviour). An
    /// empty `targetSpaceIDs` (nil target) expresses no preference. Returns the
    /// chosen display's `index`, or nil when no display's current Space is
    /// full-screen. No CGS/AX access — unit-testable in isolation.
    static func selectFullScreenDisplayIndex(
        displays: [DisplaySpaceInfo],
        targetSpaceIDs: [UInt64]
    ) -> Int? {
        let fullScreenDisplays = displays.filter { $0.currentSpaceIsFullScreen }
        guard !fullScreenDisplays.isEmpty else { return nil }
        if !targetSpaceIDs.isEmpty,
           let preferred = fullScreenDisplays.first(where: { display in
               display.spaceIDs.contains { targetSpaceIDs.contains($0) }
           }) {
            return preferred.index
        }
        return fullScreenDisplays.first?.index
    }

    /// Exit the full-screen window blocking a display. When `preferDisplayOfWindowID`
    /// is given, among displays currently showing a full-screen Space the one
    /// holding that window's Space is chosen — so a full-screen Space on the
    /// *wrong* display isn't exited on a multi-display setup. Falls back to the
    /// first full-screen display when no display matches (or the parameter is nil).
    /// Returns info about the exited window (for later re-entering full-screen).
    public func exitCurrentFullScreen(preferDisplayOfWindowID: UInt32? = nil) -> ExitedFullScreenInfo? {
        guard hasAccessibilityPermission() else { return nil }
        let cid = CGSMainConnectionID()

        guard let displaySpacesCF = CGSCopyManagedDisplaySpaces(cid),
              let displaySpaces = displaySpacesCF as? [[String: Any]] else { return nil }

        // Resolve the target window's Space(s) so we can prefer its display when
        // more than one display is currently showing a full-screen Space.
        var targetSpaceIDs: [UInt64] = []
        if let targetID = preferDisplayOfWindowID,
           let targetSpacesCF = CGSCopySpacesForWindows(cid, 0x7, [targetID as NSNumber] as CFArray),
           let ids = targetSpacesCF as? [UInt64] {
            targetSpaceIDs = ids
        }

        // Build the pure decision input: each display's Space membership plus
        // whether its current Space is full-screen.
        let displayInfos: [DisplaySpaceInfo] = displaySpaces.enumerated().map { index, displayInfo in
            let spaces = displayInfo["Spaces"] as? [[String: Any]] ?? []
            let spaceIDs = spaces.compactMap { $0["id64"] as? UInt64 }
            var currentIsFullScreen = false
            if let currentSpaceInfo = displayInfo["Current Space"] as? [String: Any],
               let currentSpaceID = currentSpaceInfo["id64"] as? UInt64 {
                currentIsFullScreen = CGSSpaceGetType(cid, currentSpaceID) == 4
            }
            return DisplaySpaceInfo(index: index, spaceIDs: spaceIDs, currentSpaceIsFullScreen: currentIsFullScreen)
        }

        guard let chosenIndex = Self.selectFullScreenDisplayIndex(
            displays: displayInfos, targetSpaceIDs: targetSpaceIDs
        ),
        let currentSpaceInfo = displaySpaces[chosenIndex]["Current Space"] as? [String: Any],
        let currentSpaceID = currentSpaceInfo["id64"] as? UInt64 else { return nil }

        print("[WP] exitCurrentFullScreen: chose display idx=\(chosenIndex) target=\(preferDisplayOfWindowID.map(String.init) ?? "nil")")

        // The chosen display's current Space is full-screen. Find the window on it.
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

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

                // Before exiting full-screen, set position/size to near-fullscreen
                // so it doesn't shrink. A full-screen window's CG bounds cover its
                // own display, so its bounds ORIGIN is that display's origin —
                // anchor to it (not a global (5,30)) so a secondary-display window
                // stays on its own display instead of teleporting to the primary.
                if let bounds = winInfo[kCGWindowBounds as String] as? [String: CGFloat],
                   let originX = bounds["X"], let originY = bounds["Y"],
                   let screenW = bounds["Width"], let screenH = bounds["Height"] {
                    // Leave a 10px margin so it's clearly not full-screen.
                    var position = CGPoint(x: originX + 5, y: originY + 30)  // below menu bar, on its own display
                    var size = CGSize(width: screenW - 10, height: screenH - 10)
                    if let posValue = AXValueCreate(.cgPoint, &position) {
                        AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
                    }
                    if let sizeValue = AXValueCreate(.cgSize, &size) {
                        AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
                    }
                    print("[WP] set window origin to \(position.x),\(position.y) size to \(size.width)x\(size.height)")
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
        return nil
    }

    /// Re-enter full-screen for a previously exited window.
    ///
    /// No windows.first tail: setting AXFullScreen on an arbitrary window is a
    /// disruptive mutation, so route the same matched/failed decision as
    /// focus()/raiseWindow() through the pure `resolution(policy: .focus, …)`
    /// helper — an ID match wins, a title match is an acceptable fallback. If
    /// neither resolves, do nothing (the window staying un-fullscreened is the
    /// correct, constraint-compliant failure) rather than full-screening a
    /// different window of the same app.
    public func reEnterFullScreen(pid: Int32, windowID: UInt32, windowTitle: String) {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            print("[WP] reEnterFullScreen: failed to get AX windows")
            return
        }

        let byID = findWindowByID(windowID, in: windows)
        let byTitle = (byID == nil) ? findWindow(matching: windowTitle, in: windows) : nil
        let window: AXUIElement? = Self.resolution(
            policy: .focus, windowID: windowID,
            idMatchFound: byID != nil, titleMatchCount: byTitle != nil ? 1 : 0
        ) == .matched ? (byID ?? byTitle) : nil

        guard let window else {
            print("[WP] reEnterFullScreen: no window match for wid=\(windowID) '\(windowTitle)'")
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

    private static let _getWindow: @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError = {
        unsafeBitCast(
            dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow"),
            to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self
        )
    }()

    /// Match AX window by CGWindowID — reliable even when multiple windows share titles.
    private func findWindowByID(_ targetID: UInt32, in windows: [AXUIElement]) -> AXUIElement? {
        guard targetID != 0 else { return nil }
        for window in windows {
            var wid: CGWindowID = 0
            if Self._getWindow(window, &wid) == .success, wid == targetID {
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
