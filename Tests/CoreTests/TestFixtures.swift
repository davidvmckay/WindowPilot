import XCTest
@testable import WindowPilotCore

// MARK: - MockWindowData

struct MockWindowData {
    let windowID: UInt32
    let ownerPID: Int32
    let ownerName: String
    let windowName: String?
    let bounds: CGRect
    let layer: Int
    let isOnscreen: Bool
}

// MARK: - TestFixtures

enum TestFixtures {

    // Three real apps plus two noise entries:
    // - SystemUIServer at layer 25 (must be excluded)
    // - Code helper process that is offscreen (must be excluded)
    static func threeAppsScenario() -> [MockWindowData] {
        return [
            // VS Code — PID 1001, 3 windows
            MockWindowData(
                windowID: 101,
                ownerPID: 1001,
                ownerName: "Code",
                windowName: "main.rs — windowpilot",
                bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                layer: 0,
                isOnscreen: true
            ),
            MockWindowData(
                windowID: 102,
                ownerPID: 1001,
                ownerName: "Code",
                windowName: "crates.io — windowpilot",
                bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                layer: 0,
                isOnscreen: true
            ),
            MockWindowData(
                windowID: 103,
                ownerPID: 1001,
                ownerName: "Code",
                windowName: "README.md — windowpilot",
                bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                layer: 0,
                isOnscreen: true
            ),

            // Terminal — PID 2001, 2 windows
            MockWindowData(
                windowID: 201,
                ownerPID: 2001,
                ownerName: "Terminal",
                windowName: "bash — ~/projects",
                bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
                layer: 0,
                isOnscreen: true
            ),
            MockWindowData(
                windowID: 202,
                ownerPID: 2001,
                ownerName: "Terminal",
                windowName: "ssh — ~/dev/server",
                bounds: CGRect(x: 150, y: 150, width: 800, height: 600),
                layer: 0,
                isOnscreen: true
            ),

            // Google Chrome — PID 3001, 2 windows
            MockWindowData(
                windowID: 301,
                ownerPID: 3001,
                ownerName: "Google Chrome",
                windowName: "Hacker News",
                bounds: CGRect(x: 200, y: 200, width: 1280, height: 800),
                layer: 0,
                isOnscreen: true
            ),
            MockWindowData(
                windowID: 302,
                ownerPID: 3001,
                ownerName: "Google Chrome",
                windowName: "crates.io — Rust package registry",
                bounds: CGRect(x: 250, y: 250, width: 1280, height: 800),
                layer: 0,
                isOnscreen: true
            ),

            // Noise: SystemUIServer at layer 25 — must be excluded
            MockWindowData(
                windowID: 901,
                ownerPID: 9001,
                ownerName: "SystemUIServer",
                windowName: nil,
                bounds: CGRect(x: 0, y: 0, width: 1440, height: 25),
                layer: 25,
                isOnscreen: true
            ),

            // Noise: Code helper process that is offscreen — must be excluded
            MockWindowData(
                windowID: 104,
                ownerPID: 1001,
                ownerName: "Code",
                windowName: "Code Helper",
                bounds: CGRect(x: -9999, y: -9999, width: 100, height: 100),
                layer: 0,
                isOnscreen: false
            ),
        ]
    }

    // Calculator — PID 4001, 1 window
    static func singleWindowApp() -> [MockWindowData] {
        return [
            MockWindowData(
                windowID: 401,
                ownerPID: 4001,
                ownerName: "Calculator",
                windowName: "Calculator",
                bounds: CGRect(x: 300, y: 300, width: 300, height: 500),
                layer: 0,
                isOnscreen: true
            ),
        ]
    }

    // SomeApp with nil and empty-string window names — both become "Untitled"
    static func nilWindowNames() -> [MockWindowData] {
        return [
            MockWindowData(
                windowID: 501,
                ownerPID: 5001,
                ownerName: "SomeApp",
                windowName: nil,
                bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                layer: 0,
                isOnscreen: true
            ),
            MockWindowData(
                windowID: 502,
                ownerPID: 5001,
                ownerName: "SomeApp",
                windowName: "",
                bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                layer: 0,
                isOnscreen: true
            ),
        ]
    }

    // `count` windows distributed across apps (5 windows per app)
    static func manyWindows(count: Int) -> [MockWindowData] {
        let windowsPerApp = 5
        var result: [MockWindowData] = []
        var windowID: UInt32 = 10000

        var remaining = count
        var appIndex = 0

        while remaining > 0 {
            let pid = Int32(10000 + appIndex)
            let appName = "App\(appIndex)"
            let windowsInThisApp = min(windowsPerApp, remaining)

            for w in 0..<windowsInThisApp {
                result.append(MockWindowData(
                    windowID: windowID,
                    ownerPID: pid,
                    ownerName: appName,
                    windowName: "\(appName) Window \(w)",
                    bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                    layer: 0,
                    isOnscreen: true
                ))
                windowID += 1
            }

            remaining -= windowsInThisApp
            appIndex += 1
        }

        return result
    }
}

// MARK: - Conversion helper

/// Converts raw MockWindowData into [AppNode] using the same rules the real
/// WindowEnumerator would apply:
///   - Exclude entries where layer != 0 or isOnscreen == false
///   - Group by ownerPID
///   - Use "Untitled" for nil or empty windowName
///   - Sort apps alphabetically by name
///   - Sort each app's windows alphabetically by title
func makeAppNodes(from data: [MockWindowData]) -> [AppNode] {
    let eligible = data.filter { $0.layer == 0 && $0.isOnscreen }

    // Group by PID
    var byPID: [Int32: (name: String, windows: [WindowInfo])] = [:]

    for entry in eligible {
        let title = (entry.windowName == nil || entry.windowName!.isEmpty)
            ? "Untitled"
            : entry.windowName!

        let info = WindowInfo(
            id: entry.windowID,
            ownerPID: entry.ownerPID,
            title: title,
            bounds: entry.bounds
        )

        if var existing = byPID[entry.ownerPID] {
            existing.windows.append(info)
            byPID[entry.ownerPID] = existing
        } else {
            byPID[entry.ownerPID] = (name: entry.ownerName, windows: [info])
        }
    }

    // Build AppNode array, sort apps alphabetically, windows alphabetically
    let nodes: [AppNode] = byPID.map { pid, value in
        let sortedWindows = value.windows.sorted { $0.title < $1.title }
        return AppNode(
            id: pid,
            name: value.name,
            bundleIdentifier: nil,
            windows: sortedWindows
        )
    }
    .sorted { $0.name < $1.name }

    return nodes
}
