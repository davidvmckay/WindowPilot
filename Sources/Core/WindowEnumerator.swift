import CoreGraphics
import ApplicationServices

/// Abstracts window discovery so callers (and tests) are not coupled to CGWindowList.
public protocol WindowEnumerating {
    /// Returns all visible application windows, optionally excluding a specific PID (e.g. our own app).
    func enumerate(excludingPID: Int32?) -> [AppNode]
}

/// Production implementation that reads from CGWindowListCopyWindowInfo.
public final class WindowEnumerator: WindowEnumerating {

    public init() {}

    private static let kLayer = kCGWindowLayer as String
    private static let kOwnerPID = kCGWindowOwnerPID as String
    private static let kOwnerName = kCGWindowOwnerName as String
    private static let kWindowName = kCGWindowName as String
    private static let kWindowNumber = kCGWindowNumber as String
    private static let kBounds = kCGWindowBounds as String
    private static let kAlpha = kCGWindowAlpha as String

    private static let minDimension: CGFloat = 50

    /// macOS system processes that create layer-0 windows but can't be focused.
    private static let blockedNames: Set<String> = [
        "AuthenticationServicesHelper",
        "universalAccessAuthWarn",
        "SharedWebCredentialViewService",
        "AccountAuthenticationDialog",
    ]

    public func enumerate(excludingPID: Int32?) -> [AppNode] {
        let displays = Self.getDisplayBounds()

        // ── Q1: on-screen windows ──
        let onScreenList = Self.queryWindows(options: [.optionOnScreenOnly, .excludeDesktopElements])

        var seenIDs = Set<UInt32>()
        var allEntries: [(entry: [String: Any], tag: String)] = []

        // Track which displays are currently showing a full-screen app
        var fullScreenDisplayIndices = Set<Int>()

        for entry in onScreenList where Self.isEligible(entry, excludingPID: excludingPID) {
            let wid = Self.windowID(from: entry)
            seenIDs.insert(wid)

            // Check if this on-screen window IS full-screen
            var tag = ""
            if let rect = Self.bounds(from: entry) {
                for (i, display) in displays.enumerated() {
                    if Self.matchesDisplay(rect, display: display) {
                        fullScreenDisplayIndices.insert(i)
                        tag = "⊞"  // mark as full-screen
                        break
                    }
                }
            }

            allEntries.append((entry, tag))
        }

        // Snapshot the Q1 (on-screen) window IDs before the Q2 merge so the AX-failure
        // fallback in detectMinimized can tell on-screen candidates (keep) from
        // off-screen ones (re-droppable when untitled).
        let onScreenIDs = seenIDs

        // ── Q2: ALL windows — find off-screen windows (other Spaces, minimized, etc.) ──
        let allList = Self.queryWindows(options: [.excludeDesktopElements])
        Self.appendOffScreenEntries(
            from: allList,
            displays: displays,
            excludingPID: excludingPID,
            seenIDs: &seenIDs,
            into: &allEntries
        )
        let offScreenIDs = seenIDs.subtracting(onScreenIDs)

        // ── Post-Q2: detect minimized windows via Accessibility ──
        // Off-screen windows with empty tags could be minimized or on another Space.
        // Use AX to check kAXMinimizedAttribute for accurate detection.
        Self.detectMinimized(&allEntries, offScreenIDs: offScreenIDs)

        // ── Build AppNodes ──
        return Self.buildAppNodes(from: allEntries)
    }

    /// Q2 merge: admit off-screen windows (other Spaces, minimized, etc.) not already
    /// seen in the Q1 on-screen pass. Extracted as an internal seam so the merge/filter
    /// rules can be unit-tested with CG-shaped dictionaries.
    ///
    /// Junk filtering is intentionally NOT done here by window name: without Screen
    /// Recording permission macOS returns no `kCGWindowName` for other apps, so a
    /// name guard would silently drop every off-screen window. Ghost surfaces are
    /// instead filtered later by AX presence (see `detectMinimized` / `buildAppNodes`).
    static func appendOffScreenEntries(
        from allList: [[String: Any]],
        displays: [CGRect],
        excludingPID: Int32?,
        seenIDs: inout Set<UInt32>,
        into allEntries: inout [(entry: [String: Any], tag: String)]
    ) {
        for entry in allList {
            let wid = windowID(from: entry)
            guard !seenIDs.contains(wid) else { continue }
            guard isEligible(entry, excludingPID: excludingPID) else { continue }
            // NOTE: no window-name guard here. macOS omits kCGWindowName for other apps
            // without Screen Recording permission, so requiring a name would drop the
            // entire off-screen pass. Untitled entries fall back to "Untitled" in
            // buildAppNodes; ghost surfaces are filtered by AX presence in detectMinimized.
            guard let rect = bounds(from: entry) else { continue }

            // Check if this window matches a display's dimensions → full-screen
            var tag = ""
            for display in displays {
                if matchesDisplay(rect, display: display) {
                    tag = "⊞"
                    break
                }
            }

            seenIDs.insert(wid)
            allEntries.append((entry, tag))
        }
    }

    // MARK: - Minimized detection via AX

    @_silgen_name("_AXUIElementGetWindow") @discardableResult
    private static func _AXUIElementGetWindow(_ el: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

    /// Real AX provider: returns each of the app's AX windows paired with its CGWindowID
    /// and minimized state, or `nil` when the `kAXWindowsAttribute` query fails outright
    /// (standalone helper/XPC processes — CursorUIViewService, AutoFill panels — expose no
    /// AX window list). This is the seam `detectMinimized` injects so its ✕/○-producing
    /// logic is unit-testable without a live Accessibility session.
    static func realAXWindows(_ pid: pid_t) -> [(id: UInt32, isMinimized: Bool)]? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return nil }

        var result: [(id: UInt32, isMinimized: Bool)] = []
        for axWindow in axWindows {
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(axWindow, &wid) == .success else { continue }

            var isMin: CFTypeRef?
            let minimized = AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &isMin) == .success
                && (isMin as? Bool) == true
            result.append((id: wid, isMinimized: minimized))
        }
        return result
    }

    /// Check off-screen windows via Accessibility API:
    /// - Tag minimized windows with "○"
    /// - Tag ghost windows (CG window exists but no AX window) with "✕"
    ///   Ghost windows are internal rendering surfaces (e.g. Ghostty zellij tabs)
    ///   that can't be focused.
    ///
    /// When the AX window-list query FAILS for an app (`axWindows` returns nil), we cannot
    /// tell ghost from real. We then re-drop only the narrow subset the pre-Task-4 name
    /// guard used to drop: candidate entries that are BOTH untitled AND off-screen. Titled
    /// entries and on-screen entries are kept unchanged — so the result is never worse than
    /// pre-fix and is strictly better whenever AX succeeds.
    ///
    /// `axWindows` is an injectable seam (defaults to `realAXWindows`); `offScreenIDs` is
    /// the set of Q2-admitted (off-screen) window IDs, computed at the call site so the
    /// fallback can distinguish on-screen candidates that must be kept.
    static func detectMinimized(
        _ entries: inout [(entry: [String: Any], tag: String)],
        offScreenIDs: Set<UInt32>,
        axWindows: (pid_t) -> [(id: UInt32, isMinimized: Bool)]? = realAXWindows
    ) {
        // Collect PIDs that have untagged off-screen windows (candidates for minimized)
        var candidatesByPID: [Int32: [Int]] = [:]  // pid → indices in entries
        for (i, item) in entries.enumerated() {
            guard item.tag.isEmpty else { continue }  // already tagged (full-screen or on-screen)
            let pid = item.entry[kOwnerPID] as? Int32 ?? -1
            candidatesByPID[pid, default: []].append(i)
        }
        guard !candidatesByPID.isEmpty else { return }

        // For each app, query AX for minimized windows and match by CGWindowID
        for (pid, indices) in candidatesByPID {
            guard let axList = axWindows(pid) else {
                // AX query FAILED for this app — cannot distinguish ghost from real.
                // Lattice-safe fallback: re-drop only the subset the pre-Task-4 name
                // guard dropped anyway — candidates that are BOTH untitled AND off-screen.
                // Titled and on-screen candidates are kept unchanged.
                for i in indices {
                    let wid = windowID(from: entries[i].entry)
                    guard offScreenIDs.contains(wid) else { continue }  // on-screen → keep
                    let name = entries[i].entry[kWindowName] as? String
                    if name == nil || name!.isEmpty {
                        entries[i].tag = "✕"  // untitled + off-screen + AX-failed → drop
                    }
                }
                continue
            }

            // Build sets of all AX window IDs and minimized IDs
            var allAXIDs = Set<UInt32>()
            var minimizedIDs = Set<UInt32>()
            for w in axList {
                allAXIDs.insert(w.id)
                if w.isMinimized { minimizedIDs.insert(w.id) }
            }

            // Tag matching entries
            for i in indices {
                let wid = windowID(from: entries[i].entry)
                if minimizedIDs.contains(wid) {
                    entries[i].tag = "○"
                } else if !allAXIDs.contains(wid) {
                    entries[i].tag = "✕"  // ghost window — no AX representation
                }
            }
        }
    }

    // MARK: - Helpers

    private static func queryWindows(options: CGWindowListOption) -> [[String: Any]] {
        CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    private static func windowID(from entry: [String: Any]) -> UInt32 {
        entry[kWindowNumber] as? UInt32
            ?? (entry[kWindowNumber] as? Int).map { UInt32($0) }
            ?? 0
    }

    private static func bounds(from entry: [String: Any]) -> CGRect? {
        guard let boundsAny = entry[kBounds] else { return nil }
        return CGRect(dictionaryRepresentation: boundsAny as! CFDictionary)
    }

    private static func isEligible(_ entry: [String: Any], excludingPID: Int32?) -> Bool {
        let layer = entry[kLayer] as? Int ?? -1
        let pid = entry[kOwnerPID] as? Int32 ?? -1
        guard layer == 0 && pid != excludingPID else { return false }

        let alpha = entry[kAlpha] as? Double ?? 1.0
        guard alpha > 0 else { return false }

        guard let rect = bounds(from: entry),
              rect.width >= minDimension && rect.height >= minDimension else {
            return false
        }

        // Filter system helper processes that create unfocusable windows
        if let name = entry[kOwnerName] as? String, blockedNames.contains(name) {
            return false
        }

        return true
    }

    /// Full-screen detection: window covers ≥97% of display width and height.
    /// Tolerates menu bar offsets, notch safe areas, and Chrome's F11 mode.
    private static func matchesDisplay(_ rect: CGRect, display: CGRect) -> Bool {
        guard display.width > 0 && display.height > 0 else { return false }
        let wRatio = rect.width / display.width
        let hRatio = rect.height / display.height
        return wRatio >= 0.97 && wRatio <= 1.01
            && hRatio >= 0.97 && hRatio <= 1.01
    }

    private static func getDisplayBounds() -> [CGRect] {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(16, &displayIDs, &displayCount)
        return (0..<Int(displayCount)).map { CGDisplayBounds(displayIDs[$0]) }
    }

    static func buildAppNodes(from entries: [(entry: [String: Any], tag: String)]) -> [AppNode] {
        var byPID: [Int32: (name: String, windows: [WindowInfo])] = [:]

        for (entry, tag) in entries where tag != "✕" {
            let pid = entry[kOwnerPID] as? Int32 ?? -1
            let ownerName = entry[kOwnerName] as? String ?? "Unknown"
            let windowName = entry[kWindowName] as? String
            let title = (windowName == nil || windowName!.isEmpty) ? "Untitled" : windowName!
            let rect = bounds(from: entry) ?? .zero

            let state: WindowState
            switch tag {
            case "⊞": state = .fullScreen
            case "○": state = .minimized
            default:  state = .normal
            }

            let info = WindowInfo(
                id: windowID(from: entry),
                ownerPID: pid,
                title: title,
                bounds: rect,
                state: state
            )

            if var existing = byPID[pid] {
                existing.windows.append(info)
                byPID[pid] = existing
            } else {
                byPID[pid] = (name: ownerName, windows: [info])
            }
        }

        return byPID.map { pid, value in
            AppNode(
                id: pid,
                name: value.name,
                bundleIdentifier: nil,
                windows: value.windows.sorted { $0.title < $1.title }
            )
        }
        .sorted { $0.name < $1.name }
    }
}
