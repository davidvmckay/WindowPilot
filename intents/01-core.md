# Intent: windowpilot-core

## Scope
`Sources/Core/` and `Tests/CoreTests/` only. Implement all pure-logic modules with full unit test coverage. **Zero AppKit imports.** This intent is optimized for Ratchet's TDD inner loop — every line of code has a corresponding automated test.

## Modules to Implement

### WindowNode.swift — Data Model
```swift
/// Represents one macOS window
public struct WindowInfo: Identifiable, Equatable {
    public let id: UInt32           // CGWindowID
    public let ownerPID: Int32
    public let title: String        // kCGWindowName, fallback to "Untitled"
    public let bounds: CGRect
}

/// Represents one running application and its windows
public struct AppNode: Identifiable, Equatable {
    public let id: Int32            // PID
    public let name: String         // resolved app display name
    public let bundleIdentifier: String?
    public var windows: [WindowInfo]
}
```

### WindowEnumerator.swift — Window Discovery
```swift
public protocol WindowEnumerating {
    func enumerate(excludingPID: Int32?) -> [AppNode]
}

/// Production implementation using CGWindowListCopyWindowInfo
public final class WindowEnumerator: WindowEnumerating { ... }
```

Core logic:
1. Call `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)`
2. Filter: `kCGWindowLayer == 0` AND `kCGWindowIsOnscreen == true`
3. Exclude windows where `kCGWindowOwnerPID == excludingPID` (our own app)
4. Group by `kCGWindowOwnerPID`
5. Resolve app name via `kCGWindowOwnerName` (use as-is, no NSRunningApplication in Core/)
6. Sort apps alphabetically by name, windows alphabetically by title
7. Return `[AppNode]`

Also implement a `MockWindowEnumerator` conforming to `WindowEnumerating` for tests.

### SearchFilter.swift — Tree Filtering
```swift
public struct SearchFilter {
    /// Filter app tree by query string. Returns filtered copy.
    /// - Empty query: returns all
    /// - Query matches app name: return that app with ALL its windows
    /// - Query matches window title only: return parent app with only matching windows
    /// - Case-insensitive substring matching
    public static func filter(_ apps: [AppNode], query: String) -> [AppNode]
}
```

### WindowCapture.swift — Screenshot Interface
```swift
public protocol WindowCapturing {
    /// Capture a screenshot of the given window. Returns nil if permission denied or capture fails.
    func capture(windowID: UInt32) -> CGImage?
    
    /// Check if screen recording permission is available
    func hasPermission() -> Bool
}

public final class WindowCapture: WindowCapturing { ... }
```

### WindowFocuser.swift — Focus Interface
```swift
public protocol WindowFocusing {
    /// Bring the specified window to front. Returns true if successful.
    func focus(pid: Int32, windowTitle: String) -> Bool
    
    /// Check if accessibility permission is available
    func hasAccessibilityPermission() -> Bool
}

public final class WindowFocuser: WindowFocusing { ... }
```

Note: WindowCapture and WindowFocuser implementations use CG/AX APIs which are macOS-specific but NOT AppKit. They belong in Core/ because they have no UI. Their protocols enable mock-based testing.

---

## Invariants

### I1: Enumeration Completeness
Every user-visible window (layer 0, on-screen) MUST appear in the result. Zero silent omissions.

**Auto-verification**:
```swift
func test_enumeration_completeness() {
    let input = TestFixtures.threeAppsScenario()
    let mock = MockWindowEnumerator(mockData: input)
    let result = mock.enumerate(excludingPID: nil)
    let totalWindows = result.flatMap(\.windows).count
    let expectedVisible = input.filter { $0.layer == 0 && $0.isOnscreen }.count
    XCTAssertEqual(totalWindows, expectedVisible)
}
```

### I2: Tree Grouping Correctness
Windows MUST be grouped under their owning application by PID. No window appears under the wrong app. No window appears twice.

**Auto-verification**:
```swift
func test_grouping_correctness() {
    let result = enumerator.enumerate(excludingPID: nil)
    // All Code windows under Code node
    let codeNode = result.first { $0.name == "Code" }!
    XCTAssertEqual(codeNode.windows.count, 3)
    XCTAssert(codeNode.windows.allSatisfy { $0.ownerPID == 1001 })
    // No duplicates globally
    let allIDs = result.flatMap(\.windows).map(\.id)
    XCTAssertEqual(allIDs.count, Set(allIDs).count)
}
```

### I3: Self-Exclusion
When `excludingPID` is provided, zero windows with that PID appear in results.

**Auto-verification**:
```swift
func test_self_exclusion() {
    let result = enumerator.enumerate(excludingPID: 5000)
    let pids = Set(result.flatMap(\.windows).map(\.ownerPID))
    XCTAssertFalse(pids.contains(5000))
}
```

---

## Quality Dimensions (minimum score: 3/5)

### Q1: Sorting Determinism (target: 5/5)
Apps always alphabetical. Windows within app always alphabetical by title. Same input always produces same output order.

### Q2: Filter Accuracy (target: 5/5)
Search never returns false positives. Search never misses a true match. Empty query always returns the full unfiltered tree.

### Q3: Edge Case Robustness (target: 4/5)
Nil window names, empty app names, zero-window apps, single-window apps, 50+ windows — all handled without crash or data loss.

---

## Test Specifications

### Test Fixtures

```swift
// Tests/CoreTests/TestFixtures.swift

struct MockWindowData {
    let windowID: UInt32
    let ownerPID: Int32
    let ownerName: String
    let windowName: String?
    let bounds: CGRect
    let layer: Int
    let isOnscreen: Bool
}

enum TestFixtures {
    
    static func threeAppsScenario() -> [MockWindowData] {
        [
            // VS Code: 3 windows
            .init(windowID: 101, ownerPID: 1001, ownerName: "Code",
                  windowName: "main.rs — VS Code", bounds: .init(x: 0, y: 0, width: 800, height: 600),
                  layer: 0, isOnscreen: true),
            .init(windowID: 102, ownerPID: 1001, ownerName: "Code",
                  windowName: "executor.rs — VS Code", bounds: .init(x: 100, y: 0, width: 800, height: 600),
                  layer: 0, isOnscreen: true),
            .init(windowID: 103, ownerPID: 1001, ownerName: "Code",
                  windowName: "CLAUDE.md — VS Code", bounds: .init(x: 200, y: 0, width: 800, height: 600),
                  layer: 0, isOnscreen: true),
            // Terminal: 2 windows
            .init(windowID: 201, ownerPID: 2001, ownerName: "Terminal",
                  windowName: "~/projects — zsh", bounds: .init(x: 0, y: 300, width: 600, height: 400),
                  layer: 0, isOnscreen: true),
            .init(windowID: 202, ownerPID: 2001, ownerName: "Terminal",
                  windowName: "~/mateclaw — cargo test", bounds: .init(x: 100, y: 300, width: 600, height: 400),
                  layer: 0, isOnscreen: true),
            // Chrome: 2 windows
            .init(windowID: 301, ownerPID: 3001, ownerName: "Google Chrome",
                  windowName: "Hacker News", bounds: .init(x: 400, y: 0, width: 900, height: 700),
                  layer: 0, isOnscreen: true),
            .init(windowID: 302, ownerPID: 3001, ownerName: "Google Chrome",
                  windowName: "crates.io", bounds: .init(x: 500, y: 0, width: 900, height: 700),
                  layer: 0, isOnscreen: true),
            // --- NOISE (should be filtered) ---
            .init(windowID: 901, ownerPID: 9001, ownerName: "SystemUIServer",
                  windowName: nil, bounds: .zero, layer: 25, isOnscreen: true),
            .init(windowID: 902, ownerPID: 1001, ownerName: "Code",
                  windowName: "helper", bounds: .zero, layer: 0, isOnscreen: false),
        ]
    }
    
    static func singleWindowApp() -> [MockWindowData] {
        [.init(windowID: 501, ownerPID: 5001, ownerName: "Calculator",
               windowName: "Calculator", bounds: .init(x: 100, y: 100, width: 300, height: 400),
               layer: 0, isOnscreen: true)]
    }
    
    static func nilWindowNames() -> [MockWindowData] {
        [
            .init(windowID: 601, ownerPID: 6001, ownerName: "SomeApp",
                  windowName: nil, bounds: .init(x: 0, y: 0, width: 400, height: 300),
                  layer: 0, isOnscreen: true),
            .init(windowID: 602, ownerPID: 6001, ownerName: "SomeApp",
                  windowName: "", bounds: .init(x: 100, y: 0, width: 400, height: 300),
                  layer: 0, isOnscreen: true),
        ]
    }
    
    static func manyWindows(count: Int) -> [MockWindowData] {
        (0..<count).map { i in
            .init(windowID: UInt32(7000 + i), ownerPID: Int32(7000 + i / 5),
                  ownerName: "App\(i / 5)", windowName: "Window\(i)",
                  bounds: .init(x: Double(i * 10), y: 0, width: 400, height: 300),
                  layer: 0, isOnscreen: true)
        }
    }
}
```

### WindowEnumerator Tests

```
test_groups_into_correct_app_count
    threeAppsScenario → 3 app nodes

test_groups_correct_window_counts
    threeAppsScenario → Code:3, Terminal:2, Chrome:2

test_filters_nonzero_layer
    threeAppsScenario → SystemUIServer (layer 25) excluded

test_filters_offscreen
    threeAppsScenario → Code's offscreen helper excluded

test_self_exclusion
    threeAppsScenario + excludingPID:1001 → no Code app in results

test_apps_sorted_alphabetically
    threeAppsScenario → ["Code", "Google Chrome", "Terminal"]

test_windows_sorted_by_title
    Code's windows → ["CLAUDE.md — VS Code", "executor.rs — VS Code", "main.rs — VS Code"]

test_empty_input
    [] → []

test_single_window_app
    singleWindowApp → 1 app with 1 window

test_nil_window_names_use_fallback
    nilWindowNames → window titles are "Untitled" (or similar), not nil/crash

test_no_duplicate_window_ids
    threeAppsScenario → all window IDs unique globally

test_many_windows_performance
    manyWindows(50) → completes in < 10ms (logic only, no CG calls)
```

### SearchFilter Tests

```
test_empty_query_returns_all
    query "" + threeAppsScenario → 3 apps, 7 windows total

test_match_app_name
    query "terminal" → 1 app (Terminal) with all 2 windows

test_match_window_title
    query "main.rs" → 1 app (Code) with 1 window (main.rs)

test_case_insensitive
    query "CHROME" → matches Google Chrome

test_no_match
    query "zzzzz" → 0 apps

test_partial_app_returns_all_windows
    query "code" → Code app with all 3 windows

test_partial_window_returns_only_matching
    query "hacker" → Google Chrome with only Hacker News window

test_match_across_app_and_title
    query "chrome crates" → Google Chrome with crates.io window
    (this tests that both app name and window title contribute to matching)

test_whitespace_handling
    query "  terminal  " → still matches Terminal (trim input)

test_special_characters
    query "~/" → matches Terminal windows with paths
```

### WindowNode Tests

```
test_appnode_equality
    Two AppNodes with same PID → equal

test_windowinfo_equality
    Two WindowInfos with same windowID → equal

test_windowinfo_title_fallback
    WindowInfo created with nil name → title is "Untitled"
```

---

## Completion Criteria

All of the following must be true for `/ratchet:review`:

1. `swift test --filter WindowPilotCoreTests` — **all tests pass, zero failures**
2. `swift build` compiles without warnings in Core/ target
3. No `import AppKit` or `import Cocoa` anywhere in `Sources/Core/`
4. All public types have at minimum a one-line doc comment
5. MockWindowEnumerator exists and conforms to WindowEnumerating protocol
