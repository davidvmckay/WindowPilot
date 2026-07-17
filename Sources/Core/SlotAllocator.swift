import Foundation

// MARK: - SlotAllocator

/// Parking-lot placement for the sidebar's dynamic zone.
///
/// Invariants (spatial stability — the whole point of the sidebar):
/// - A seated window keeps its position until it dies or is evicted.
/// - Focus changes never reshuffle seated windows.
/// - Newcomers fill empty positions first, then replace the coldest
///   seated window IN PLACE.
public struct SlotAllocator: Equatable {

    public private(set) var slots: [UInt32?]

    public init(capacity: Int) {
        slots = Array(repeating: nil, count: max(0, capacity))
    }

    /// Reconcile slots with the current world.
    /// - Parameters:
    ///   - live: window IDs eligible for the dynamic zone (pinned windows
    ///     already excluded by the caller)
    ///   - priority: hottest-first ranking (e.g. MRU); windows absent from
    ///     the list rank coldest
    public mutating func sync(live: Set<UInt32>, priority: [UInt32]) {
        var rank: [UInt32: Int] = [:]
        for (i, w) in priority.enumerated() where rank[w] == nil { rank[w] = i }
        func rankOf(_ w: UInt32) -> Int { rank[w] ?? Int.max }

        // 1. Dead windows free their slots; survivors do not move.
        for i in slots.indices {
            if let w = slots[i], !live.contains(w) { slots[i] = nil }
        }

        // 2. Newcomers: live, not seated — hottest first.
        let seated = Set(slots.compactMap { $0 })
        var newcomers = priority.filter { live.contains($0) && !seated.contains($0) }

        // 2a. Fill empty positions top-down.
        for i in slots.indices where slots[i] == nil {
            guard !newcomers.isEmpty else { break }
            slots[i] = newcomers.removeFirst()
        }

        // 2b. Evict in place: a hotter newcomer replaces the coldest seated window.
        for newcomer in newcomers {
            guard let coldestIndex = slots.indices
                .filter({ slots[$0] != nil })
                .max(by: { rankOf(slots[$0]!) < rankOf(slots[$1]!) })
            else { break }
            guard rankOf(newcomer) < rankOf(slots[coldestIndex]!) else { continue }
            slots[coldestIndex] = newcomer
        }
    }
}
