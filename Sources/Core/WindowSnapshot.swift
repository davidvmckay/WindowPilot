import CoreGraphics

/// One on-screen window from a single CGWindowList snapshot.
///
/// `bounds` are in CoreGraphics **global** coordinates: top-left origin, Y
/// increasing downward — the SAME space `CGDisplayBounds` reports. (Cocoa's
/// `NSScreen.frame` is the opposite: bottom-left origin. Callers that start
/// from an `NSScreen` must resolve a CG frame — e.g. via `CGDisplayBounds` of
/// the screen's display ID — before comparing against these bounds.)
///
/// `layer` 0 is the normal application-window layer; higher layers are system
/// UI (menu bar, Dock, notifications, etc.).
public struct WindowSnapshotEntry: Equatable {
    public let id: UInt32
    public let pid: Int32
    public let bounds: CGRect
    public let layer: Int

    public init(id: UInt32, pid: Int32, bounds: CGRect, layer: Int) {
        self.id = id
        self.pid = pid
        self.bounds = bounds
        self.layer = layer
    }
}

/// Wrapped CGWindowList access — the shared window-snapshot seam the App/UI
/// layers use instead of calling CoreGraphics window APIs directly (see the
/// "All CG calls are wrapped" architecture rule). Deliberately minimal for now;
/// Task 6 extends it to absorb the remaining raw CGWindowList call sites.
public enum WindowSnapshot {

    private static let kLayer = kCGWindowLayer as String
    private static let kOwnerPID = kCGWindowOwnerPID as String
    private static let kWindowNumber = kCGWindowNumber as String
    private static let kBounds = kCGWindowBounds as String

    /// One CGWindowList fetch of the currently on-screen application windows
    /// (desktop wallpaper/icons excluded). Bounds are CG global top-left coords.
    public static func onScreenWindows() -> [WindowSnapshotEntry] {
        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return list.compactMap(entry(from:))
    }

    /// True when a fresh snapshot contains a layer-0 window covering
    /// `displayFrame`. Convenience wrapper over the pure predicate that
    /// performs the CGWindowList fetch.
    ///
    /// `displayFrame` MUST be in CG global coordinates (e.g. `CGDisplayBounds`
    /// of the target display) so it shares the snapshot's coordinate space —
    /// no Cocoa Y-flip happens here or in the predicate. A degenerate frame
    /// (zero width/height, e.g. an unresolved display) yields `false`.
    public static func hasLayerZeroWindowCovering(
        displayFrame: CGRect, coverage: CGFloat = 0.97
    ) -> Bool {
        hasLayerZeroWindowCovering(
            in: onScreenWindows(), displayFrame: displayFrame, coverage: coverage
        )
    }

    /// Pure coverage predicate (no CG calls): `true` iff some entry on layer 0
    /// overlaps `displayFrame` by at least `coverage` of the display's area.
    /// Both `entries` bounds and `displayFrame` are assumed CG global coords, so
    /// the overlap is a direct rect intersection with no coordinate flipping.
    static func hasLayerZeroWindowCovering(
        in entries: [WindowSnapshotEntry], displayFrame: CGRect, coverage: CGFloat = 0.97
    ) -> Bool {
        guard displayFrame.width > 0, displayFrame.height > 0 else { return false }
        let displayArea = displayFrame.width * displayFrame.height
        for entry in entries where entry.layer == 0 {
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
        return WindowSnapshotEntry(id: id, pid: pid, bounds: bounds, layer: layer)
    }
}
