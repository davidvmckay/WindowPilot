import AppKit

/// Shared test infrastructure for opening and closing real macOS windows via AppleScript.
/// All methods are safe to call in a headless environment — they will silently no-op.
enum TestWindowHarness {

    /// Open `count` TextEdit documents, each with a unique marker string as its body.
    /// Returns the marker titles in creation order.
    /// Waits 500ms between opens to let the window appear in CGWindowList.
    static func openTextEditWindows(count: Int) async -> [String] {
        var titles: [String] = []
        for i in 1...count {
            let marker = "WPTest_\(UUID().uuidString.prefix(6))_\(i)"
            let script = """
            tell application "TextEdit"
                activate
                make new document with properties {text:"\(marker)"}
            end tell
            """
            NSAppleScript(source: script)?.executeAndReturnError(nil)
            titles.append(marker)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return titles
    }

    /// Close all TextEdit documents without saving and quit the app.
    static func cleanupTextEdit() {
        let script = """
        tell application "TextEdit"
            close every document saving no
            quit
        end tell
        """
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    /// Launch Calculator (single-window app). Does not wait for it to become ready.
    static func openCalculator() {
        // Use openApplication(at:configuration:completionHandler:) to avoid the macOS 11
        // deprecation of NSWorkspace.launchApplication(_:).
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.calculator") {
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    /// Quit Calculator.
    static func closeCalculator() {
        let script = "tell application \"Calculator\" to quit"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    /// Sleep for `ms` milliseconds. Convenience wrapper so test bodies stay readable.
    static func sleep(ms: UInt64) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }
}
