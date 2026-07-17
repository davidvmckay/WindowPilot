import XCTest
import WindowPilotCore

final class SlotAllocatorTests: XCTestCase {

    func testFillsEmptySlotsTopDownByPriority() {
        var a = SlotAllocator(capacity: 3)
        a.sync(live: [10, 20], priority: [20, 10])
        XCTAssertEqual(a.slots, [20, 10, nil])
    }

    func testFocusChangeNeverReshufflesSeatedWindows() {
        var a = SlotAllocator(capacity: 3)
        a.sync(live: [10, 20, 30], priority: [10, 20, 30])
        let before = a.slots
        // Same world, totally different priority order — nothing may move.
        a.sync(live: [10, 20, 30], priority: [30, 20, 10])
        XCTAssertEqual(a.slots, before)
    }

    func testDeadWindowFreesItsSlotOthersStay() {
        var a = SlotAllocator(capacity: 3)
        a.sync(live: [10, 20, 30], priority: [10, 20, 30])
        a.sync(live: [10, 30], priority: [10, 30])
        XCTAssertEqual(a.slots, [10, nil, 30])
    }

    func testNewcomerFillsFreedSlotInPlace() {
        var a = SlotAllocator(capacity: 3)
        a.sync(live: [10, 20, 30], priority: [10, 20, 30])
        a.sync(live: [10, 30], priority: [10, 30])           // frees middle
        a.sync(live: [10, 30, 40], priority: [40, 10, 30])   // 40 takes the freed middle slot
        XCTAssertEqual(a.slots, [10, 40, 30])
    }

    func testHotNewcomerEvictsColdestInPlace() {
        var a = SlotAllocator(capacity: 3)
        a.sync(live: [10, 20, 30], priority: [10, 20, 30])
        // Zone full. 40 is hottest; 30 is coldest → replaced in place (index 2).
        a.sync(live: [10, 20, 30, 40], priority: [40, 10, 20, 30])
        XCTAssertEqual(a.slots, [10, 20, 40])
    }

    func testColdNewcomerDoesNotEvictHotterSeated() {
        var a = SlotAllocator(capacity: 2)
        a.sync(live: [10, 20], priority: [10, 20])
        // 30 is colder than both seated windows → no change.
        a.sync(live: [10, 20, 30], priority: [10, 20, 30])
        XCTAssertEqual(a.slots, [10, 20])
    }

    func testUnrankedWindowsRankColdest() {
        var a = SlotAllocator(capacity: 2)
        a.sync(live: [10, 20], priority: [10, 20])
        // 20 vanished from priority (unranked) → coldest; 30 (ranked) evicts it in place.
        a.sync(live: [10, 20, 30], priority: [30, 10])
        XCTAssertEqual(a.slots, [10, 30])
    }

    func testZeroCapacity() {
        var a = SlotAllocator(capacity: 0)
        a.sync(live: [10], priority: [10])
        XCTAssertEqual(a.slots, [])
    }

    func testDuplicatePriorityEntriesDoNotDuplicateWindows() {
        var a = SlotAllocator(capacity: 3)
        a.sync(live: [10], priority: [10])
        a.sync(live: [10, 40], priority: [40, 40])
        XCTAssertEqual(a.slots, [10, 40, nil])
    }

    func testDuplicateNewcomerCannotEvictTwice() {
        var a = SlotAllocator(capacity: 2)
        a.sync(live: [10, 20], priority: [10, 20])
        // 40 duplicated: must evict exactly one (the coldest: 20), never both.
        a.sync(live: [10, 20, 40], priority: [40, 40, 10, 20])
        XCTAssertEqual(a.slots, [10, 40])
    }

    func testUnrankedLiveWindowIsNotAdmitted() {
        var a = SlotAllocator(capacity: 2)
        a.sync(live: [10, 20], priority: [10])
        XCTAssertEqual(a.slots, [10, nil])
    }
}
