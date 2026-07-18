import AppKit

/// Shared test infrastructure for opening and closing real macOS windows via AppleScript.
/// All methods are safe to call in a headless environment — they will silently no-op.
enum TestWindowHarness {

    /// Temp fixture files created by `openTextEditWindows`, tracked so `cleanupTextEdit`
    /// can remove them.
    private static var openedFileURLs: [URL] = []

    /// Open `count` TextEdit documents, each backed by a temp .txt file whose name is a
    /// unique marker. TextEdit titles its window from the document's filename, not its
    /// body text, so naming the file is what makes the marker observable in the title.
    /// Returns the marker strings (sans extension) in creation order.
    /// Waits 500ms between opens to let each window appear in CGWindowList.
    static func openTextEditWindows(count: Int) async -> [String] {
        var titles: [String] = []
        let tempDir = FileManager.default.temporaryDirectory
        let textEditURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")

        for i in 1...count {
            let marker = "WPTest_\(UUID().uuidString.prefix(6))_\(i)"
            let fileURL = tempDir.appendingPathComponent("\(marker).txt")
            try? marker.write(to: fileURL, atomically: true, encoding: .utf8)
            openedFileURLs.append(fileURL)

            if let textEditURL {
                // Equivalent of `open -a TextEdit <file>`: the window title becomes
                // the filename, which carries the marker.
                _ = try? await NSWorkspace.shared.open(
                    [fileURL],
                    withApplicationAt: textEditURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            }

            titles.append(marker)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return titles
    }

    /// Close all TextEdit documents without saving, quit the app, and delete any temp
    /// fixture files created by `openTextEditWindows`.
    static func cleanupTextEdit() {
        let script = """
        tell application "TextEdit"
            close every document saving no
            quit
        end tell
        """
        NSAppleScript(source: script)?.executeAndReturnError(nil)

        for url in openedFileURLs {
            try? FileManager.default.removeItem(at: url)
        }
        openedFileURLs.removeAll()
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
