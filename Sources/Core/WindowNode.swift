import CoreGraphics

/// Window state as detected during enumeration.
public enum WindowState: Hashable {
    case normal
    case fullScreen
    case minimized
}

/// Represents one macOS window.
public struct WindowInfo: Identifiable, Hashable {
    public let id: UInt32
    public let ownerPID: Int32
    public let title: String
    public let bounds: CGRect
    public let state: WindowState

    public init(id: UInt32, ownerPID: Int32, title: String, bounds: CGRect, state: WindowState = .normal) {
        self.id = id
        self.ownerPID = ownerPID
        self.title = title
        self.bounds = bounds
        self.state = state
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
            && lhs.ownerPID == rhs.ownerPID
            && lhs.title == rhs.title
            && lhs.bounds == rhs.bounds
            && lhs.state == rhs.state
    }
}

/// Represents one running application and its windows.
public struct AppNode: Identifiable, Hashable {
    public let id: Int32
    public let name: String
    public let bundleIdentifier: String?
    public var windows: [WindowInfo]

    public init(id: Int32, name: String, bundleIdentifier: String?, windows: [WindowInfo]) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.windows = windows
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: AppNode, rhs: AppNode) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.windows == rhs.windows
    }

    /// Returns a copy with `bundleIdentifier` replaced. Core has no AppKit,
    /// so it cannot look up bundle IDs itself (that needs NSRunningApplication);
    /// this pure copy helper lets the App layer enrich enumeration results
    /// at the boundary instead.
    public func withBundleIdentifier(_ bundleIdentifier: String?) -> AppNode {
        AppNode(id: id, name: name, bundleIdentifier: bundleIdentifier, windows: windows)
    }
}
