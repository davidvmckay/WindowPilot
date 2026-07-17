import XCTest
import WindowPilotCore

final class PinStoreTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wp-pinstore-tests-\(UUID().uuidString)")
            .appendingPathComponent("pins.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeApps() -> [AppNode] {
        [
            AppNode(id: 100, name: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty", windows: [
                WindowInfo(id: 1, ownerPID: 100, title: "zsh — build", bounds: .zero),
                WindowInfo(id: 2, ownerPID: 100, title: "zsh — logs", bounds: .zero),
            ]),
            AppNode(id: 200, name: "Safari", bundleIdentifier: "com.apple.Safari", windows: [
                WindowInfo(id: 3, ownerPID: 200, title: "PR #42 — GitHub", bounds: .zero),
            ]),
        ]
    }

    func testPinUnpinAndFirstFree() {
        let store = PinStore(capacity: 3, fileURL: tempURL)
        let p = PinnedWindow(bundleIdentifier: "com.apple.Safari", appName: "Safari", title: "PR #42 — GitHub")
        XCTAssertEqual(store.pinFirstFree(p), 0)
        store.pin(PinnedWindow(bundleIdentifier: nil, appName: "Ghostty", title: "zsh — build"), at: 2)
        XCTAssertEqual(store.pins[0], p)
        XCTAssertNil(store.pins[1])
        store.unpin(at: 0)
        XCTAssertNil(store.pins[0])
    }

    func testPersistsAcrossInstances() {
        let p = PinnedWindow(bundleIdentifier: "com.apple.Safari", appName: "Safari", title: "PR #42 — GitHub")
        do {
            let store = PinStore(capacity: 3, fileURL: tempURL)
            store.pin(p, at: 1)
        }
        let reloaded = PinStore(capacity: 3, fileURL: tempURL)
        XCTAssertEqual(reloaded.pins, [nil, p, nil])
    }

    func testResolveExactTitleWins() {
        let store = PinStore(capacity: 3, fileURL: tempURL)
        let pin = PinnedWindow(bundleIdentifier: "com.mitchellh.ghostty", appName: "Ghostty", title: "zsh — logs")
        XCTAssertEqual(store.resolve(pin, in: makeApps())?.id, 2)
    }

    func testResolveFuzzyTitleFallsBack() {
        let store = PinStore(capacity: 3, fileURL: tempURL)
        // Title drifted: pin has old suffix, live window title is a prefix-match.
        let pin = PinnedWindow(bundleIdentifier: "com.apple.Safari", appName: "Safari", title: "PR #42 — GitHub — reviewing")
        XCTAssertEqual(store.resolve(pin, in: makeApps())?.id, 3)
    }

    func testResolveAppOnlyFallback() {
        let store = PinStore(capacity: 3, fileURL: tempURL)
        let pin = PinnedWindow(bundleIdentifier: "com.mitchellh.ghostty", appName: "Ghostty", title: "totally gone")
        XCTAssertEqual(store.resolve(pin, in: makeApps())?.id, 1)
    }

    func testResolveDeadAppReturnsNil() {
        let store = PinStore(capacity: 3, fileURL: tempURL)
        let pin = PinnedWindow(bundleIdentifier: "com.figma.Desktop", appName: "Figma", title: "Mockups")
        XCTAssertNil(store.resolve(pin, in: makeApps()))
    }

    func testBundleIDPreferredOverAppName() {
        let store = PinStore(capacity: 3, fileURL: tempURL)
        // Same appName, different bundleID → must NOT match.
        let pin = PinnedWindow(bundleIdentifier: "com.other.Ghostty", appName: "Ghostty", title: "zsh — build")
        XCTAssertNil(store.resolve(pin, in: makeApps()))
    }
}
