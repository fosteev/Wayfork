import Foundation

/// Fixed-capacity FIFO keeping the newest elements (log tails for reattach).
public struct RingBuffer<Element: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    public mutating func append(contentsOf elements: some Sequence<Element>) {
        for element in elements { append(element) }
    }

    /// Oldest first.
    public var elements: [Element] {
        Array(storage[head...]) + Array(storage[..<head])
    }

    /// The newest `n` elements, oldest first.
    public func suffix(_ n: Int) -> [Element] {
        Array(elements.suffix(n))
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}
