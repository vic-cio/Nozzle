import Foundation

public enum NozzleControlAction: Codable, Equatable, Sendable {
    case status
    case connect
    case disconnect
    case home(Set<PrinterAxis>)
    case jog(axis: PrinterAxis, millimetres: Double)
    case heat(heater: Heater, celsius: Double)
    case extrude(millimetres: Double)
    case heatersOff
    case motorsOff
    case send(command: String, confirmedDangerous: Bool)

    private enum CodingKeys: String, CodingKey {
        case type, axes, axis, millimetres, heater, celsius, command, confirmedDangerous
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(String.self, forKey: .type)
        switch type {
        case "status": self = .status
        case "connect": self = .connect
        case "disconnect": self = .disconnect
        case "home": self = .home(try values.decode(Set<PrinterAxis>.self, forKey: .axes))
        case "jog": self = .jog(axis: try values.decode(PrinterAxis.self, forKey: .axis), millimetres: try values.decode(Double.self, forKey: .millimetres))
        case "heat": self = .heat(heater: try values.decode(Heater.self, forKey: .heater), celsius: try values.decode(Double.self, forKey: .celsius))
        case "extrude": self = .extrude(millimetres: try values.decode(Double.self, forKey: .millimetres))
        case "heatersOff": self = .heatersOff
        case "motorsOff": self = .motorsOff
        case "send": self = .send(command: try values.decode(String.self, forKey: .command), confirmedDangerous: try values.decode(Bool.self, forKey: .confirmedDangerous))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Unknown control action: \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status: try values.encode("status", forKey: .type)
        case .connect: try values.encode("connect", forKey: .type)
        case .disconnect: try values.encode("disconnect", forKey: .type)
        case .home(let axes):
            try values.encode("home", forKey: .type); try values.encode(axes, forKey: .axes)
        case .jog(let axis, let millimetres):
            try values.encode("jog", forKey: .type); try values.encode(axis, forKey: .axis); try values.encode(millimetres, forKey: .millimetres)
        case .heat(let heater, let celsius):
            try values.encode("heat", forKey: .type); try values.encode(heater, forKey: .heater); try values.encode(celsius, forKey: .celsius)
        case .extrude(let millimetres):
            try values.encode("extrude", forKey: .type); try values.encode(millimetres, forKey: .millimetres)
        case .heatersOff: try values.encode("heatersOff", forKey: .type)
        case .motorsOff: try values.encode("motorsOff", forKey: .type)
        case .send(let command, let confirmedDangerous):
            try values.encode("send", forKey: .type); try values.encode(command, forKey: .command); try values.encode(confirmedDangerous, forKey: .confirmedDangerous)
        }
    }
}

public struct NozzleControlRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let action: NozzleControlAction

    public init(id: UUID = UUID(), action: NozzleControlAction) {
        self.schemaVersion = 1
        self.id = id
        self.action = action
    }
}

public struct ControlTemperature: Codable, Equatable, Sendable {
    public let current: Double
    public let target: Double?
    public init(current: Double, target: Double?) { self.current = current; self.target = target }
}

public struct ControlPosition: Codable, Equatable, Sendable {
    public let x: Double?
    public let y: Double?
    public let z: Double?
    public let e: Double?
    public init(x: Double?, y: Double?, z: Double?, e: Double?) {
        self.x = x; self.y = y; self.z = z; self.e = e
    }
}

public struct NozzleControlSnapshot: Codable, Equatable, Sendable {
    public let activity: String
    public let connected: Bool
    public let operation: String?
    public let portPath: String?
    public let hotend: ControlTemperature?
    public let bed: ControlTemperature?
    public let position: ControlPosition?
    public let homedAxes: [PrinterAxis]
    public let firmware: String?

    public init(activity: String, connected: Bool, operation: String?, portPath: String?, hotend: ControlTemperature?, bed: ControlTemperature?, position: ControlPosition?, homedAxes: [PrinterAxis], firmware: String?) {
        self.activity = activity; self.connected = connected; self.operation = operation
        self.portPath = portPath; self.hotend = hotend; self.bed = bed; self.position = position
        self.homedAxes = homedAxes; self.firmware = firmware
    }
}

public struct NozzleControlFailure: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}

public struct NozzleControlResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID?
    public let snapshot: NozzleControlSnapshot?
    public let error: NozzleControlFailure?

    public static func success(requestID: UUID, snapshot: NozzleControlSnapshot) -> Self {
        Self(schemaVersion: 1, requestID: requestID, snapshot: snapshot, error: nil)
    }

    public static func failure(requestID: UUID?, code: String, message: String, snapshot: NozzleControlSnapshot? = nil) -> Self {
        Self(schemaVersion: 1, requestID: requestID, snapshot: snapshot, error: NozzleControlFailure(code: code, message: message))
    }
}

public enum NozzleControlEndpoint {
    public static var defaultSocketURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Nozzle/control.sock")
    }
}
