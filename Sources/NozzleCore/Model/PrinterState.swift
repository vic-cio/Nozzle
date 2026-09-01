import Foundation

/// The single, obvious answer to "what is the printer doing right now?".
///
/// Combines the link layer's state with job state so the UI has one thing to switch on.
public enum PrinterActivity: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case printing
    case paused
    case error(String)

    /// The words shown in the status pill.
    public var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected"
        case .printing:     return "Printing"
        case .paused:       return "Paused"
        case .error:        return "Error"
        }
    }

    public var isConnected: Bool {
        switch self {
        case .connected, .printing, .paused: return true
        case .disconnected, .connecting, .error: return false
        }
    }

    /// True when the printer is executing a job and must not be disturbed.
    public var isJobActive: Bool {
        self == .printing || self == .paused
    }
}

/// One point on the temperature graph.
public struct TemperatureSample: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let time: Date
    public let hotend: Double?
    public let hotendTarget: Double?
    public let bed: Double?
    public let bedTarget: Double?

    public init(time: Date, hotend: Double?, hotendTarget: Double?, bed: Double?, bedTarget: Double?) {
        self.time = time
        self.hotend = hotend
        self.hotendTarget = hotendTarget
        self.bed = bed
        self.bedTarget = bedTarget
    }
}

/// A snapshot of everything known about the machine.
///
/// A plain value type on purpose: it can be constructed in a test, compared, and
/// handed to a SwiftUI view without dragging along a serial port.
public struct PrinterState: Sendable, Equatable {
    public var activity: PrinterActivity = .disconnected
    public var portPath: String?
    public var baudRate: Int = BaudRate.marlinDefault
    public var firmware: FirmwareInfo?

    public var hotend: HeaterTemperature?
    public var bed: HeaterTemperature?
    public var lastTemperatureUpdate: Date?

    /// Reported position. `nil` until the printer has been homed or asked via `M114` —
    /// which is exactly why we refuse to jog before homing: we genuinely do not know
    /// where the nozzle is.
    public var position: PositionReport?

    /// The axes that have been homed since this connection began.
    ///
    /// Tracked per axis because `G28 X` is a real thing the user can press, and because
    /// telling them "Y and Z still need homing" is more use than "not homed". Cleared
    /// whenever the truth is in doubt: motors off, a board reset, a disconnect.
    public var homedAxes: Set<PrinterAxis> = []

    public var hasHomedAllAxes: Bool { homedAxes.count == PrinterAxis.allCases.count }

    /// The axes still to home, in X, Y, Z order.
    public var unhomedAxes: [PrinterAxis] { PrinterAxis.allCases.filter { !homedAxes.contains($0) } }

    /// The printer is chewing on a long command (`busy: processing`).
    public var isBusy = false
    /// Most recent firmware `Error:` line, for display.
    public var lastFirmwareError: String?

    public init() {}

    /// Is the hotend hot enough for the firmware to allow extrusion?
    public func canExtrude(profile: PrinterProfile) -> Bool {
        guard let hotend else { return false }
        return hotend.current >= profile.minimumExtrusionTemperature
    }

    /// Plain-English reason extrusion is blocked, or `nil` if it is allowed.
    public func extrusionBlockedReason(profile: PrinterProfile) -> String? {
        guard activity.isConnected else { return "Connect to the printer first." }
        if activity.isJobActive { return "The printer is in the middle of a job." }
        guard let hotend else { return "Waiting for a temperature reading from the printer." }
        let minimum = Int(profile.minimumExtrusionTemperature)
        guard hotend.current >= profile.minimumExtrusionTemperature else {
            return "The nozzle is \(Int(hotend.current)) °C. Pushing filament through a cold nozzle "
                 + "strips the filament and can jam the extruder, so the firmware blocks it below "
                 + "\(minimum) °C. Heat the nozzle first."
        }
        return nil
    }

    /// Plain-English reason jogging is blocked, or `nil` if it is allowed.
    ///
    /// All three axes must be homed before *any* of them may be jogged, not just the one
    /// being moved. Marlin only enforces its software endstops once an axis is homed, and
    /// on this machine homing Z depends on where X and Y are — so a partly homed printer
    /// is one where a move can still end in the frame.
    public func movementBlockedReason() -> String? {
        guard activity.isConnected else { return "Connect to the printer first." }
        if activity.isJobActive { return "The printer is in the middle of a job." }
        guard hasHomedAllAxes else {
            let remaining = unhomedAxes.map(\.rawValue).joined(separator: ", ")
            return "Home the printer first — \(remaining) still to go. Until an axis has homed, the "
                 + "firmware does not know where it is, so it cannot stop a move from hitting the "
                 + "frame or the bed."
        }
        return nil
    }

    /// Plain-English reason homing is blocked, or `nil` if it is allowed.
    public func homingBlockedReason() -> String? {
        guard activity.isConnected else { return "Connect to the printer first." }
        if activity.isJobActive { return "The printer is in the middle of a job." }
        return nil
    }
}
