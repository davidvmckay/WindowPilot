import XCTest
@testable import WindowPilotCore

final class WindowNodeTests: XCTestCase {

    // Two AppNodes constructed with the same PID must be equal.
    func test_appnode_equality() {
        let windows: [WindowInfo] = [
            WindowInfo(
                id: 101,
                ownerPID: 1001,
                title: "main.rs",
                bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
            )
        ]
        let a = AppNode(id: 1001, name: "Code", bundleIdentifier: nil, windows: windows)
        let b = AppNode(id: 1001, name: "Code", bundleIdentifier: nil, windows: windows)

        XCTAssertEqual(a, b)
    }

    // Two WindowInfos constructed with the same windowID must be equal.
    func test_windowinfo_equality() {
        let a = WindowInfo(
            id: 42,
            ownerPID: 999,
            title: "My Window",
            bounds: CGRect(x: 0, y: 0, width: 1280, height: 800)
        )
        let b = WindowInfo(
            id: 42,
            ownerPID: 999,
            title: "My Window",
            bounds: CGRect(x: 0, y: 0, width: 1280, height: 800)
        )

        XCTAssertEqual(a, b)
    }

    // WindowInfo stores the title it is initialised with.
    // The nil-name fallback to "Untitled" happens during enumeration (tested
    // in WindowEnumeratorTests), so here we verify the struct simply stores
    // whatever title string it receives — in this case the already-resolved
    // "Untitled" value.
    func test_windowinfo_title_fallback() {
        let info = WindowInfo(
            id: 1,
            ownerPID: 100,
            title: "Untitled",
            bounds: CGRect(x: 0, y: 0, width: 400, height: 300)
        )

        XCTAssertEqual(info.title, "Untitled")
    }
}
