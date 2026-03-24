import Foundation

// MARK: - TrackedWindow

/// A window with activity tracking data.
public struct TrackedWindow: Hashable, Identifiable {
    public let id: UInt32           // CGWindowID
    public let pid: Int32
    public let appName: String
    public let bundleIdentifier: String?
    public var windowTitle: String
    public var lastFocusTime: Date
    public var totalDuration: TimeInterval

    public var durationText: String {
        let minutes = Int(totalDuration) / 60
        let seconds = Int(totalDuration) % 60
        if minutes >= 60 {
            return "\(minutes / 60)h\(minutes % 60)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "\(seconds)s"
        }
    }

    public var agoText: String {
        let interval = Date().timeIntervalSince(lastFocusTime)
        let seconds = Int(interval)
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }
}

// MARK: - WindowActivityTracker

/// Tracks window focus activity for the current session.
/// Call `windowDidFocus(...)` whenever the focused window changes.
/// Core module — no AppKit imports. The App layer handles NSWorkspace
/// notifications and calls into this tracker.
public final class WindowActivityTracker {

    // MARK: State

    /// All tracked windows, keyed by windowID.
    private var windows: [UInt32: TrackedWindow] = [:]

    /// The currently active window (timer running).
    private var activeWindowID: UInt32?
    private var activeStartTime: Date?

    public init() {}

    // MARK: Public API

    /// Record that a window became the focused window.
    /// Stops the timer on the previous window, starts one on the new window.
    public func windowDidFocus(
        windowID: UInt32,
        pid: Int32,
        appName: String,
        bundleIdentifier: String?,
        windowTitle: String
    ) {
        // Stop timer on previous window
        snapshotActiveWindow()

        // Update or create entry for the new window
        if var entry = windows[windowID] {
            entry.lastFocusTime = Date()
            entry.windowTitle = windowTitle  // title may have changed
            windows[windowID] = entry
        } else {
            windows[windowID] = TrackedWindow(
                id: windowID,
                pid: pid,
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                lastFocusTime: Date(),
                totalDuration: 0
            )
        }

        // Start timer on new window
        activeWindowID = windowID
        activeStartTime = Date()
    }

    /// Snapshot the current active window's elapsed time without stopping the timer.
    /// Call this before reading data to get up-to-date durations.
    public func recordDuration() {
        snapshotActiveWindow()
        // Restart timer (don't stop it)
        if activeWindowID != nil {
            activeStartTime = Date()
        }
    }

    /// Windows sorted by last focus time (most recent first).
    public func recentWindows(limit: Int = 20) -> [TrackedWindow] {
        Array(
            windows.values
                .sorted { $0.lastFocusTime > $1.lastFocusTime }
                .prefix(limit)
        )
    }

    /// Windows sorted by total active duration (longest first).
    public func topWindows(limit: Int = 20) -> [TrackedWindow] {
        Array(
            windows.values
                .sorted { $0.totalDuration > $1.totalDuration }
                .prefix(limit)
        )
    }

    /// Combined ranking: weighted by both recency and duration.
    /// Score = recencyWeight * recencyScore + durationWeight * durationScore
    public func combinedRanking(limit: Int = 20) -> [TrackedWindow] {
        let now = Date()
        let allWindows = Array(windows.values)
        guard !allWindows.isEmpty else { return [] }

        // Normalize recency: 0 (oldest) to 1 (most recent)
        let maxAge = allWindows.map { now.timeIntervalSince($0.lastFocusTime) }.max() ?? 1
        let normalizedAge = maxAge > 0 ? maxAge : 1

        // Normalize duration: 0 (shortest) to 1 (longest)
        let maxDuration = allWindows.map { $0.totalDuration }.max() ?? 1
        let normalizedDuration = maxDuration > 0 ? maxDuration : 1

        let scored = allWindows.map { window -> (TrackedWindow, Double) in
            let recencyScore = 1.0 - (now.timeIntervalSince(window.lastFocusTime) / normalizedAge)
            let durationScore = window.totalDuration / normalizedDuration
            // Weight recency higher (0.6) than duration (0.4)
            let score = 0.6 * recencyScore + 0.4 * durationScore
            return (window, score)
        }

        return Array(
            scored
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
                .prefix(limit)
        )
    }

    /// Whether there is any tracked data.
    public var hasData: Bool { !windows.isEmpty }

    // MARK: Private

    private func snapshotActiveWindow() {
        guard let windowID = activeWindowID,
              let startTime = activeStartTime,
              var entry = windows[windowID] else { return }
        entry.totalDuration += Date().timeIntervalSince(startTime)
        windows[windowID] = entry
    }
}
