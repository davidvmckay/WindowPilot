import Foundation

// MARK: - PinnedWindow

/// A pinned sidebar slot, persisted across app restarts. windowIDs don't
/// survive restarts, so pins re-resolve against live windows by
/// (bundleIdentifier/appName, title) heuristics.
public struct PinnedWindow: Codable, Equatable {
    public let bundleIdentifier: String?
    public let appName: String
    public let title: String

    public init(bundleIdentifier: String?, appName: String, title: String) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.title = title
    }
}

// MARK: - PinStore

/// Fixed pinned positions with JSON persistence. Pure logic, no AppKit.
public final class PinStore {

    public let capacity: Int
    public private(set) var pins: [PinnedWindow?]
    private let fileURL: URL

    public init(capacity: Int, fileURL: URL) {
        self.capacity = max(0, capacity)
        self.fileURL = fileURL
        self.pins = Array(repeating: nil, count: self.capacity)
        load()
    }

    public func pin(_ window: PinnedWindow, at index: Int) {
        guard pins.indices.contains(index) else { return }
        pins[index] = window
        save()
    }

    /// Pin into the first empty position. Returns the index, or nil if full.
    @discardableResult
    public func pinFirstFree(_ window: PinnedWindow) -> Int? {
        guard let i = pins.firstIndex(where: { $0 == nil }) else { return nil }
        pins[i] = window
        save()
        return i
    }

    public func unpin(at index: Int) {
        guard pins.indices.contains(index) else { return }
        pins[index] = nil
        save()
    }

    /// Resolve a pin to a live window.
    /// Match order: same app + exact title → same app + prefix/contains
    /// → same app any window → nil (dead).
    /// "Same app": bundleIdentifier equality when both sides have one,
    /// otherwise appName equality.
    public func resolve(_ pin: PinnedWindow, in apps: [AppNode]) -> WindowInfo? {
        let candidates = apps.filter { app in
            if let pinBundle = pin.bundleIdentifier, let appBundle = app.bundleIdentifier {
                return pinBundle == appBundle
            }
            return app.name == pin.appName
        }
        let windows = candidates.flatMap { $0.windows }
        if let exact = windows.first(where: { $0.title == pin.title }) { return exact }
        if let fuzzy = windows.first(where: {
            $0.title.hasPrefix(pin.title) || pin.title.hasPrefix($0.title)
                || (!pin.title.isEmpty && $0.title.contains(pin.title))
        }) { return fuzzy }
        return windows.first
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([PinnedWindow?].self, from: data) else {
            print("[WP] PinStore: corrupt pins file at \(fileURL.path) — ignoring")
            return
        }
        for (i, p) in decoded.prefix(capacity).enumerated() { pins[i] = p }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(pins)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[WP] PinStore: save failed — \(error)")
        }
    }
}
