import Foundation

/// Reassembles the byte chunks a serial port hands us into whole lines.
///
/// USB serial reads split wherever the driver feels like it, so `ok T:199` and
/// `.8 /200.0\n` routinely arrive as two separate reads. Parsing a partial line
/// would mean missing an `ok` and stalling the queue forever, so all line-splitting
/// happens here, once, and is unit-tested independently of any port.
public struct LineAssembler: Sendable {
    private var buffer: [UInt8] = []
    /// Guards against a wedged printer streaming megabytes with no newline.
    private let maxLineLength: Int

    public init(maxLineLength: Int = 4_096) {
        self.maxLineLength = maxLineLength
    }

    /// Feeds bytes in and returns whatever complete lines that produced.
    public mutating func append(_ bytes: [UInt8]) -> [String] {
        var lines: [String] = []
        for byte in bytes {
            switch byte {
            case 0x0A:  // \n
                lines.append(flush())
            case 0x0D:  // \r — Marlin sends bare \n, but forks and adapters vary
                continue
            default:
                buffer.append(byte)
                if buffer.count >= maxLineLength {
                    lines.append(flush())
                }
            }
        }
        return lines
    }

    private mutating func flush() -> String {
        // Marlin is ASCII, but a wrong baud rate produces invalid bytes; decode
        // leniently so garbage is visible in the Console instead of being dropped.
        let text = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return text
    }

    /// Discards any partial line, e.g. after a reconnect.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}
