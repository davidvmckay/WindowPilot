import CoreGraphics

/// One window from a single CGWindowList snapshot.
///
/// `bounds` are in CoreGraphics **global** coordinates: top-left origin, Y
/// increasing downward — the SAME space `CGDisplayBounds` reports. (Cocoa's
/// `NSScreen.frame` is the opposite: bottom-left origin. Callers that start
/// from an `NSScreen` must resolve a CG frame — e.g. via `CGDisplayBounds` of
/// the screen's display ID — before comparing against these bounds.)
///
/// `layer` 0 is the normal application-window layer; higher layers are system
/// UI (menu bar, Dock, notifications, etc.).
///
/// `title` is the `kCGWindowName` value with a `kCGWindowOwnerName` fallback
/// (empty string when neither is present, e.g. no Screen Recording permission);
/// only the on-screen full-screen-exit path reads it.
public struct WindowSnapshotEntry: Equatable {
    public let id: UInt32
    public let pid: Int32
    public let bounds: CGRect
    public let layer: Int
    public let title: String

    public init(id: UInt32, pid: Int32, bounds: CGRect, layer: Int, title: String = "") {
        self.id = id
        self.pid = pid
        self.bounds = bounds
        self.layer = layer
        self.title = title
    }
}

/// Wrapped CGWindowList access — the shared window-snapshot seam the App/UI
/// layers use instead of calling CoreGraphics window APIs directly (see the
/// "All CG calls are wrapped" architecture rule). Deliberately minimal: it
/// carries only the fields the wrapped call sites read.
public enum WindowSnapshot {

    private static let kLayer = kCGWindowLayer as String
    private static let kOwnerPID = kCGWindowOwnerPID as String
    private static let kOwnerName = kCGWindowOwnerName as String
    private static let kWindowName = kCGWindowName as String
    private static let kWindowNumber = kCGWindowNumber as String
    private static let kBounds = kCGWindowBounds as String

    /// One CGWindowList fetch of the currently on-screen application windows
    /// (desktop wallpaper/icons excluded). Bounds are CG global top-left coords.
    ///
    /// `excludingPID` drops windows owned by that process (our own PID at the
    /// suppression-clear call site) so a coverage decision never counts our own
    /// windows — the guarantee is the layer-0 filter PLUS this PID exclusion,
    /// not the implicit "all our windows sit above layer 0" invariant.
    public static func onScreenWindows(excludingPID: Int32? = nil) -> [WindowSnapshotEntry] {
        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return list.compactMap(entry(from:)).filter {
            excludingPID == nil || $0.pid != excludingPID
        }
    }

    /// One CGWindowList fetch of ALL windows (`.optionAll` — on- and off-screen,
    /// every layer). The focus tracker takes a single such snapshot per tick and
    /// looks up individual windows in it via `entry(forWindowID:in:)`.
    public static func allWindows() -> [WindowSnapshotEntry] {
        let list = CGWindowListCopyWindowInfo(
            [.optionAll], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return list.compactMap(entry(from:))
    }

    /// Pure lookup (no CG calls): the entry for `id` in an already-fetched
    /// snapshot, or `nil` when absent. Window IDs are unique, so the first match
    /// is the only match.
    public static func entry(forWindowID id: UInt32, in entries: [WindowSnapshotEntry]) -> WindowSnapshotEntry? {
        entries.first { $0.id == id }
    }

    /// True when a fresh snapshot contains a layer-0 window covering
    /// `displayFrame`. Convenience wrapper over the pure predicate that
    /// performs the CGWindowList fetch, excluding `excludingPID` at the source.
    ///
    /// `displayFrame` MUST be in CG global coordinates (e.g. `CGDisplayBounds`
    /// of the target display) so it shares the snapshot's coordinate space —
    /// no Cocoa Y-flip happens here or in the predicate. A degenerate frame
    /// (zero width/height, e.g. an unresolved display) yields `false`.
    ///
    /// The `coverage` default of 0.995 targets borderless, AX-less fullscreen
    /// surfaces (games, video players) that cover 100% of `CGDisplayBounds`. It
    /// deliberately sits above a maximized window's reach: a maximized
    /// (non-fullscreen) window leaves the menu bar visible — ≥ ~1.4% of the
    /// display height — so it tops out around ~98.6% on any realistic display
    /// (~97.8% on a 1080pt-high display, ~98.3% on a 27" 2K). 0.995 separates
    /// the two with margin on both sides, so the front app's OWN maximized
    /// window (whose AX read may transiently fail, routing here) never trips
    /// this fallback. No bounds-equality check is needed: the intersection math
    /// already clamps a window LARGER than the display to the overlap, so a
    /// slightly-oversized fullscreen surface still counts.
    ///
    /// `owningPID` non-nil means only windows owned by that process can count
    /// as the covering surface (attribution: the front app must be the one
    /// covering the display); `nil` preserves the any-PID semantics — any
    /// layer-0 window may register as coverage. Forwarded to the predicate.
    public static func hasLayerZeroWindowCovering(
        displayFrame: CGRect, coverage: CGFloat = 0.995,
        excludingPID: Int32? = nil, owningPID: Int32? = nil
    ) -> Bool {
        hasLayerZeroWindowCovering(
            in: onScreenWindows(excludingPID: excludingPID),
            displayFrame: displayFrame, coverage: coverage, owningPID: owningPID
        )
    }

    /// Pure coverage predicate (no CG calls): `true` iff some entry on layer 0
    /// (and not owned by `excludingPID`) overlaps `displayFrame` by at least
    /// `coverage` of the display's area. Both `entries` bounds and `displayFrame`
    /// are assumed CG global coords, so the overlap is a direct rect intersection
    /// with no coordinate flipping. The convenience overload above filters
    /// `excludingPID` at fetch time and leaves this defaulted to `nil`; the
    /// parameter keeps the exclusion expressible (and unit-testable) for callers
    /// that pass unfiltered entries directly.
    ///
    /// `coverage` defaults to 0.995 — see the convenience overload for why that
    /// separates an AX-less fullscreen surface (~100%) from a maximized window
    /// (~97.8–98.6%, menu bar still showing).
    ///
    /// `owningPID` non-nil means only windows owned by that process can count
    /// as the covering surface (attribution: the front app must be the one
    /// covering the display — so a maximized BACKGROUND window from a different
    /// app never registers as coverage); `nil` preserves the any-PID semantics.
    /// This is the inverse test of `excludingPID`: `excludingPID` drops one
    /// process, `owningPID` keeps only one.
    static func hasLayerZeroWindowCovering(
        in entries: [WindowSnapshotEntry], displayFrame: CGRect,
        coverage: CGFloat = 0.995, excludingPID: Int32? = nil, owningPID: Int32? = nil
    ) -> Bool {
        guard displayFrame.width > 0, displayFrame.height > 0 else { return false }
        let displayArea = displayFrame.width * displayFrame.height
        for entry in entries
        where entry.layer == 0
            && (excludingPID == nil || entry.pid != excludingPID)
            && (owningPID == nil || entry.pid == owningPID) {
            let overlap = entry.bounds.intersection(displayFrame)
            guard !overlap.isNull else { continue }
            if overlap.width * overlap.height >= coverage * displayArea { return true }
        }
        return false
    }

    private static func entry(from info: [String: Any]) -> WindowSnapshotEntry? {
        guard let boundsAny = info[kBounds],
              let bounds = CGRect(dictionaryRepresentation: boundsAny as! CFDictionary) else {
            return nil
        }
        let id = info[kWindowNumber] as? UInt32
            ?? (info[kWindowNumber] as? Int).map { UInt32($0) } ?? 0
        let pid = info[kOwnerPID] as? Int32
            ?? (info[kOwnerPID] as? Int).map { Int32($0) } ?? -1
        let layer = info[kLayer] as? Int ?? -1
        let title = (info[kWindowName] as? String)
            ?? (info[kOwnerName] as? String) ?? ""
        return WindowSnapshotEntry(id: id, pid: pid, bounds: bounds, layer: layer, title: title)
    }
}
