import Foundation

/// One line of the Console.
public struct TrafficEntry: Identifiable, Sendable, Equatable {
    public enum Direction: String, Sendable, CaseIterable {
        case tx = "TX"      // host → printer
        case rx = "RX"      // printer → host
        case info = "··"    // Nozzle's own commentary
        case warning = "!!" // something the user should notice
    }

    public let id: UUID
    public let timestamp: Date
    public let direction: Direction
    public let text: String

    public init(direction: Direction, text: String, timestamp: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.timestamp = timestamp
        self.direction = direction
        self.text = text
    }

    /// `20:14:03.412  TX: M105`
    public func formatted(timeFormatter: DateFormatter) -> String {
        "\(timeFormatter.string(from: timestamp))  \(direction.rawValue): \(text)"
    }
}

/// A bounded, append-only log. Bounded on purpose: a long print emits hundreds of
/// thousands of lines and an unbounded array would eventually exhaust memory.
public struct TrafficLog: Sendable {
    public private(set) var entries: [TrafficEntry] = []
    public let capacity: Int
    /// Lines dropped because the log was full, so the Console can be honest about it.
    public private(set) var droppedCount: Int = 0

    public init(capacity: Int = 5_000) {
        self.capacity = capacity
        entries.reserveCapacity(min(capacity, 1_024))
    }

    public mutating func append(_ entry: TrafficEntry) {
        entries.append(entry)
        if entries.count > capacity {
            let overflow = entries.count - capacity
            entries.removeFirst(overflow)
            droppedCount += overflow
        }
    }

    public mutating func clear() {
        entries.removeAll(keepingCapacity: true)
        droppedCount = 0
    }

    /// Plain text for copy/export.
    public func exportText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        var lines: [String] = []
        if droppedCount > 0 {
            lines.append("… \(droppedCount) earlier line(s) dropped from the buffer …")
        }
        lines.append(contentsOf: entries.map { $0.formatted(timeFormatter: formatter) })
        return lines.joined(separator: "\n")
    }
}
