import Foundation

/// Something that can carry raw bytes to and from a printer.
///
/// This layer knows *nothing* about Marlin, G-code, `ok`, or temperatures — it is
/// purely "bytes in, bytes out". That separation is what lets `MarlinConnection`
/// be tested against `MockMarlinPrinter` with no hardware attached.
public protocol SerialTransport: AnyObject, Sendable {
    /// Human-readable identifier, e.g. `/dev/cu.usbserial-1110` or `Demo Printer`.
    var displayPath: String { get }

    /// A single-consumer stream of transport events. Created once, at init.
    var events: AsyncStream<SerialEvent> { get }

    var isOpen: Bool { get }

    /// Opens the port. Throws rather than reporting failure through `events`,
    /// so that a failed connect is impossible to mistake for a successful one.
    func open() throws

    /// Writes bytes, retrying on partial writes. Blocking, but cheap.
    func write(_ bytes: [UInt8]) throws

    /// Closes the port and finishes the `events` stream.
    ///
    /// A transport is single-use: to reconnect, build a new one. This removes a
    /// whole class of "stale reader thread from the last connection" bugs.
    func close()
}

public enum SerialEvent: Sendable {
    case opened
    case data([UInt8])
    /// The port went away. `error` is nil for a clean, host-initiated close.
    case closed(SerialError?)
}

public enum SerialError: Error, LocalizedError, Sendable, Equatable {
    case cannotOpen(path: String, code: Int32)
    case notOpen
    case alreadyOpen
    case configurationFailed(step: String, code: Int32)
    case baudRateRejected(requested: Int, actual: Int)
    case writeFailed(code: Int32)
    case readFailed(code: Int32)
    /// Read returned EOF or the device node vanished — USB cable pulled, printer powered off.
    case deviceDisconnected

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let path, let code):
            let reason = String(cString: strerror(code))
            if code == EBUSY {
                return "\(path) is busy. Another program (Pronterface, Arduino IDE, Cura) may still have it open."
            }
            if code == EACCES {
                return "Not allowed to open \(path) (\(reason))."
            }
            return "Could not open \(path): \(reason)."
        case .notOpen:
            return "The serial port is not open."
        case .alreadyOpen:
            return "The serial port is already open."
        case .configurationFailed(let step, let code):
            return "Could not configure the serial port (\(step)): \(String(cString: strerror(code)))."
        case .baudRateRejected(let requested, let actual):
            return "The USB adapter refused \(requested) baud and is running at \(actual) baud instead. "
                 + "Pick a different speed — on macOS this usually means the driver cannot do non-standard rates."
        case .writeFailed(let code):
            return "Failed to send data to the printer: \(String(cString: strerror(code)))."
        case .readFailed(let code):
            return "Failed to read from the printer: \(String(cString: strerror(code)))."
        case .deviceDisconnected:
            return "The printer disconnected. Check the USB cable and that the printer is powered on."
        }
    }
}

/// Baud rates worth offering for a Marlin machine.
public enum BaudRate {
    public static let common: [Int] = [115_200, 250_000, 57_600, 38_400, 19_200, 9_600]
    public static let marlinDefault = 115_200
}
