import Foundation

public enum CLICommand: Equatable, Sendable {
    case help(json: Bool)
    case version
    case ports(includeDialin: Bool)
    case profile(path: String?)
    case inspect(path: String, profile: String?, validate: Bool)
    case commands(path: String, offset: Int, limit: Int)
    case assess(String)

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
            if ["--json", "--help", "-h", "--version", "--include-dialin"].contains(argument) {
                guard flags.insert(argument).inserted else { throw CLIError.usage("Duplicate option: \(argument)") }
            } else if ["--profile", "--offset", "--limit"].contains(argument) {
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
