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

        // ── Q2: ALL windows — find off-screen windows (other Spaces, minimized, etc.) ──
        let allList = Self.queryWindows(options: [.excludeDesktopElements])

        for entry in allList {
            let wid = Self.windowID(from: entry)
            guard !seenIDs.contains(wid) else { continue }
            guard Self.isEligible(entry, excludingPID: excludingPID) else { continue }
            guard let name = entry[Self.kWindowName] as? String, !name.isEmpty else { continue }
            guard let rect = Self.bounds(from: entry) else { continue }

            // Check if this window matches a display's dimensions → full-screen
            var tag = ""
            for display in displays {
                if Self.matchesDisplay(rect, display: display) {
                    tag = "⊞"
                    break
                }
            }

            seenIDs.insert(wid)
            allEntries.append((entry, tag))
        }

        // ── Post-Q2: detect minimized windows via Accessibility ──
        // Off-screen windows with empty tags could be minimized or on another Space.
        // Use AX to check kAXMinimizedAttribute for accurate detection.
        Self.detectMinimized(&allEntries)

        // ── Build AppNodes ──
        return Self.buildAppNodes(from: allEntries)
    }

    // MARK: - Minimized detection via AX

    @_silgen_name("_AXUIElementGetWindow") @discardableResult
    private static func _AXUIElementGetWindow(_ el: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

    /// Check off-screen windows via Accessibility API:
    /// - Tag minimized windows with "○"
    /// - Tag ghost windows (CG window exists but no AX window) with "✕"
    ///   Ghost windows are internal rendering surfaces (e.g. Ghostty zellij tabs)
    ///   that can't be focused.
    private static func detectMinimized(_ entries: inout [(entry: [String: Any], tag: String)]) {
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
            let appElement = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement] else { continue }

            // Build sets of all AX window IDs and minimized IDs
            var allAXIDs = Set<UInt32>()
            var minimizedIDs = Set<UInt32>()
            for axWindow in axWindows {
                var wid: CGWindowID = 0
                guard _AXUIElementGetWindow(axWindow, &wid) == .success else { continue }
                allAXIDs.insert(wid)

                var isMin: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &isMin) == .success,
                   (isMin as? Bool) == true {
                    minimizedIDs.insert(wid)
                }
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

    private static func buildAppNodes(from entries: [(entry: [String: Any], tag: String)]) -> [AppNode] {
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
