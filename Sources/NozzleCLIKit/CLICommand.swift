import Foundation
import NozzleCore

public enum CLICommand: Equatable, Sendable {
    case help(json: Bool)
    case version
    case ports(includeDialin: Bool)
    case profile(path: String?)
    case inspect(path: String, profile: String?, validate: Bool)
    case commands(path: String, offset: Int, limit: Int)
    case assess(String)
    case live(NozzleControlAction, socketPath: String?)

    public static func parse(_ arguments: [String]) throws -> CLICommand {
        var words: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var literal = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if literal { words.append(argument); continue }
            if argument == "--" { literal = true; continue }
            if ["--json", "--help", "-h", "--version", "--include-dialin", "--confirm-dangerous"].contains(argument) {
                guard flags.insert(argument).inserted else { throw CLIError.usage("Duplicate option: \(argument)") }
            } else if ["--profile", "--offset", "--limit", "--socket", "--axes"].contains(argument) {
                guard options[argument] == nil else { throw CLIError.usage("Duplicate option: \(argument)") }
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw CLIError.usage("Missing value for \(argument)")
                }
                options[argument] = arguments[index]
                index += 1
            } else if argument.hasPrefix("-") {
                throw CLIError.usage("Unknown option: \(argument). Use -- before paths beginning with '-'.")
            } else { words.append(argument) }
        }
        if flags.contains("--help") || flags.contains("-h") || words == ["help"] || arguments.isEmpty {
            return .help(json: flags.contains("--json"))
        }
        func allow(_ allowed: Set<String> = [], flags allowedFlags: Set<String> = []) throws {
            let unexpected = Set(options.keys).subtracting(allowed).union(flags.subtracting(allowedFlags.union(["--json"])))
            if let option = unexpected.sorted().first { throw CLIError.usage("Option \(option) is not supported for this command.") }
        }
        if flags.contains("--version") && words.isEmpty {
            try allow(flags: ["--version"])
            return .version
        }
        switch words {
        case ["ports"]:
            try allow(flags: ["--include-dialin"])
            return .ports(includeDialin: flags.contains("--include-dialin"))
        case ["profile", "show"]:
            try allow(["--profile"])
            return .profile(path: options["--profile"])
        default: break
        }
        if words.count == 3 && words[0] == "file" {
            switch words[1] {
            case "inspect", "validate":
                try allow(["--profile"])
                return .inspect(path: words[2], profile: options["--profile"], validate: words[1] == "validate")
            case "commands":
                try allow(["--offset", "--limit"])
                func integer(_ option: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
                    guard let raw = options[option] else { return fallback }
                    guard let value = Int(raw), range.contains(value) else {
                        throw CLIError.usage("\(option) must be an integer in \(range).")
                    }
                    return value
                }
                return .commands(path: words[2], offset: try integer("--offset", fallback: 0, range: 0...Int.max),
                                 limit: try integer("--limit", fallback: 100, range: 1...1000))
            default: break
            }
        }
        if words.count == 3 && words[0...1] == ["command", "assess"] {
            try allow()
            guard !words[2].contains(where: { $0.isNewline }),
                  !words[2].trimmingCharacters(in: .whitespaces).isEmpty else {
                throw CLIError.usage("Supply one nonempty, quoted console command.")
            }
            return .assess(words[2])
        }
        if words.first == "live" {
            try allow(["--socket", "--axes"], flags: ["--confirm-dangerous"])
            let socket = options["--socket"]
            let action: NozzleControlAction
            let liveWords = Array(words.dropFirst())
            switch liveWords {
            case ["status"]: action = .status
            case ["connect"]: action = .connect
            case ["disconnect"]: action = .disconnect
            case ["heaters-off"]: action = .heatersOff
            case ["motors-off"]: action = .motorsOff
            case ["home"]:
                let letters = options["--axes"] ?? ""
                guard letters.allSatisfy({ "XYZ".contains($0) }), Set(letters).count == letters.count else {
                    throw CLIError.usage("--axes must contain each of X, Y, and Z at most once.")
                }
                action = .home(Set(letters.compactMap { PrinterAxis(rawValue: String($0)) }))
            case let values where values.count == 3 && values[0] == "jog":
                let rawAxis = values[1], rawDistance = values[2]
                guard let axis = PrinterAxis(rawValue: rawAxis.uppercased()),
                      let distance = Double(rawDistance), distance.isFinite, distance != 0 else {
                    throw CLIError.usage("Jog requires X, Y, or Z and a finite nonzero distance in millimetres.")
                }
                action = .jog(axis: axis, millimetres: distance)
            case let values where values.count == 3 && values[0] == "heat":
                let rawHeater = values[1], rawTemperature = values[2]
                let heater: Heater? = rawHeater == "nozzle" ? .hotend : rawHeater == "bed" ? .bed : nil
                guard let heater, let temperature = Double(rawTemperature), temperature.isFinite else {
                    throw CLIError.usage("Heat requires nozzle or bed and a finite temperature in Celsius.")
                }
                action = .heat(heater: heater, celsius: temperature)
            case let values where values.count == 2 && values[0] == "extrude":
                let rawDistance = values[1]
                guard let distance = Double(rawDistance), distance.isFinite, distance != 0 else {
                    throw CLIError.usage("Extrude requires a finite nonzero distance in millimetres.")
                }
                action = .extrude(millimetres: distance)
            case let values where values.count == 2 && values[0] == "send":
                let command = values[1]
                let cleaned = command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty, !cleaned.contains(where: { $0.isNewline }) else {
                    throw CLIError.usage("Send requires one nonempty, quoted console command.")
                }
                let confirmed = flags.contains("--confirm-dangerous")
                guard !CommandSafety.assess(cleaned).requiresConfirmation || confirmed else {
                    throw CLIError.usage("This command is dangerous. Re-run with --confirm-dangerous after reviewing it.")
                }
                action = .send(command: cleaned, confirmedDangerous: confirmed)
            default: throw CLIError.usage("Unknown live command or incorrect arguments. Run nozzle-cli --help.")
            }
            if options["--axes"] != nil, !words.starts(with: ["live", "home"]) {
                throw CLIError.usage("Option --axes is only supported for live home.")
            }
            if flags.contains("--confirm-dangerous"), !words.starts(with: ["live", "send"]) {
                throw CLIError.usage("Option --confirm-dangerous is only supported for live send.")
            }
            return .live(action, socketPath: socket)
        }
        throw CLIError.usage("Unknown command or incorrect arguments. Run nozzle-cli --help.")
    }
}

public struct CLIError: Error, Encodable, Sendable {
    public let code: String
    public let message: String
    public let exitCode: Int32

    public init(code: String, message: String, exitCode: Int32 = 1) {
        self.code = code; self.message = message; self.exitCode = exitCode
    }
    static func usage(_ message: String) -> CLIError { CLIError(code: "usage", message: message, exitCode: 2) }
}
