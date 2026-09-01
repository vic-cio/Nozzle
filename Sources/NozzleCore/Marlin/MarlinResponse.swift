import Foundation

/// One heater's current and requested temperature.
public struct HeaterTemperature: Equatable, Sendable {
    public var current: Double
    /// `nil` when the firmware reported a reading with no setpoint.
    public var target: Double?

    public init(current: Double, target: Double? = nil) {
        self.current = current
        self.target = target
    }

    /// True when the heater is actively being driven somewhere.
    public var isHeating: Bool { (target ?? 0) > 0 }

    /// "198 / 200 °C"
    public func formatted() -> String {
        let now = String(format: "%.0f", current)
        guard let target, target > 0 else { return "\(now) °C" }
        return "\(now) / \(String(format: "%.0f", target)) °C"
    }
}

/// A parsed `M105` / autoreport temperature line.
public struct TemperatureReport: Equatable, Sendable {
    /// Hotends by index. A single-extruder machine reports `T:` which lands at index 0.
    public var hotends: [Int: HeaterTemperature]
    public var bed: HeaterTemperature?
    public var chamber: HeaterTemperature?
    /// Hotend PWM duty from `@:` (0–127), if reported.
    public var hotendPower: Int?
    /// Bed PWM duty from `B@:`.
    public var bedPower: Int?

    public init(
        hotends: [Int: HeaterTemperature] = [:],
        bed: HeaterTemperature? = nil,
        chamber: HeaterTemperature? = nil,
        hotendPower: Int? = nil,
        bedPower: Int? = nil
    ) {
        self.hotends = hotends
        self.bed = bed
        self.chamber = chamber
        self.hotendPower = hotendPower
        self.bedPower = bedPower
    }

    /// The active hotend on a single-extruder machine.
    public var hotend: HeaterTemperature? { hotends[0] }

    public var isEmpty: Bool { hotends.isEmpty && bed == nil && chamber == nil }
}

/// A parsed `M114` position report.
public struct PositionReport: Equatable, Sendable {
    public var x: Double?
    public var y: Double?
    public var z: Double?
    public var e: Double?

    public init(x: Double? = nil, y: Double? = nil, z: Double? = nil, e: Double? = nil) {
        self.x = x; self.y = y; self.z = z; self.e = e
    }
}

/// Everything `M115` told us about the machine.
///
/// Nothing here is assumed from the printer model: a second-hand Ender-5 Pro may be
/// running anything. Fields stay `nil`/`false` unless the firmware actually said so.
public struct FirmwareInfo: Equatable, Sendable {
    public var firmwareName: String?
    public var machineType: String?
    public var protocolVersion: String?
    public var sourceCodeURL: String?
    public var extruderCount: Int?
    public var uuid: String?
    /// Raw `Cap:NAME:0|1` reports, keyed by capability name.
    public var capabilities: [String: Bool]
    /// The unparsed lines, so the Console can show exactly what arrived.
    public var rawLines: [String]

    public init(
        firmwareName: String? = nil,
        machineType: String? = nil,
        protocolVersion: String? = nil,
        sourceCodeURL: String? = nil,
        extruderCount: Int? = nil,
        uuid: String? = nil,
        capabilities: [String: Bool] = [:],
        rawLines: [String] = []
    ) {
        self.firmwareName = firmwareName
        self.machineType = machineType
        self.protocolVersion = protocolVersion
        self.sourceCodeURL = sourceCodeURL
        self.extruderCount = extruderCount
        self.uuid = uuid
        self.capabilities = capabilities
        self.rawLines = rawLines
    }

    public func supports(_ capability: Capability) -> Bool {
        capabilities[capability.rawValue] ?? false
    }

    /// The capabilities Nozzle actually changes its behaviour for.
    public enum Capability: String, Sendable {
        /// `M155 S<seconds>` — the printer pushes temperatures on its own, so we never
        /// have to spend a queue slot on `M105` while streaming a print.
        case autoreportTemperature = "AUTOREPORT_TEMP"
        /// `M154 S<seconds>` — same idea for position.
        case autoreportPosition = "AUTOREPORT_POS"
        /// Without this, `M112` queues behind pending moves and is not a real stop.
        case emergencyParser = "EMERGENCY_PARSER"
        case hostActionCommands = "HOST_ACTION_COMMANDS"
        case promptSupport = "PROMPT_SUPPORT"
        case autoLevel = "AUTOLEVEL"
        case eeprom = "EEPROM"
        case thermalProtection = "THERMAL_PROTECTION"
        case babystepping = "BABYSTEPPING"
        case pauseStop = "PAUSESTOP"
    }

    /// "Marlin 2.0.8.2" or a fallback.
    public var shortDescription: String {
        firmwareName ?? machineType ?? "Unknown firmware"
    }
}

/// The payload of an `ok`.
public struct OkInfo: Equatable, Sendable {
    /// From `ADVANCED_OK`: the line number being acknowledged.
    public var lineNumber: Int?
    /// From `ADVANCED_OK`: free slots in the motion planner.
    public var plannerFree: Int?
    /// From `ADVANCED_OK`: free slots in the command buffer. Lets us size our window
    /// from what the firmware reports instead of guessing.
    public var bufferFree: Int?
    /// Some firmwares append a temperature report to the `ok` for `M105`.
    public var temperature: TemperatureReport?

    public init(
        lineNumber: Int? = nil,
        plannerFree: Int? = nil,
        bufferFree: Int? = nil,
        temperature: TemperatureReport? = nil
    ) {
        self.lineNumber = lineNumber
        self.plannerFree = plannerFree
        self.bufferFree = bufferFree
        self.temperature = temperature
    }
}

/// One classified line received from the printer.
public enum MarlinResponse: Equatable, Sendable {
    /// Command acknowledged — the only thing that frees a queue slot.
    case ok(OkInfo)
    /// The board booted (power-on, reset, or DTR toggle when we opened the port).
    case start
    /// `echo:busy: processing` — still alive, still working. Not an acknowledgement.
    case busy
    /// Idle prompt some firmwares emit. Ignorable.
    case wait
    /// `Resend: N` / `rs N` — retransmit from line N.
    case resend(line: Int)
    /// `Error:...`
    case error(String)
    /// A temperature line that arrived on its own (autoreport), not attached to an `ok`.
    case temperature(TemperatureReport)
    case position(PositionReport)
    /// A single `Cap:NAME:1` line.
    case capability(name: String, enabled: Bool)
    /// The `FIRMWARE_NAME:...` line.
    case firmware(FirmwareInfo)
    /// `echo:` chatter, e.g. `echo:SD init fail`.
    case echo(String)
    /// `//action:paused`, `//action:prompt_begin ...` — host action commands.
    case action(String)
    /// Anything we did not recognise. Still shown in the Console, never silently dropped.
    case unknown(String)

    /// Whether this response completes an outstanding command.
    public var isAcknowledgement: Bool {
        if case .ok = self { return true }
        return false
    }
}
