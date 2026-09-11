import Foundation
import NozzleCore

public struct CLIOutput: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
}

/// The executable only writes these streams and exits. No GUI or serial connection is opened.
public enum CLIRunner {
    public static let help = """
    Nozzle CLI — offline G-code tools and serial device discovery
    Usage:
      nozzle-cli [--help | --version] [--json]
      nozzle-cli ports [--include-dialin]
      nozzle-cli profile show [--profile PATH]
      nozzle-cli file inspect PATH [--profile PATH]
      nozzle-cli file validate PATH [--profile PATH]
      nozzle-cli file commands PATH [--offset N] [--limit N]
      nozzle-cli command assess 'M112'

    All commands emit one JSON document; help is text unless --json is present.
    --json is accepted on every command. -- ends option parsing.
    Profiles default to stock Ender-5 Pro, never ambient app preferences.
    Command pages use zero-based offsets (default 0), limit 1–1000 (default 100),
    and one-based source line numbers. No command opens a printer or sends G-code.
    Validation uses Nozzle's metadata checks, not a motion simulation or safety proof.
    Exit: 0 success, 1 input/I/O error, 2 usage error, 3 blocking validation findings.
    """

    public static func run(_ arguments: [String]) -> CLIOutput {
        do { return try execute(CLICommand.parse(arguments)) }
        catch let error as CLIError { return failure(error) }
        catch let error as GCodeError {
            return failure(CLIError(code: "gcode_input", message: error.localizedDescription))
        } catch {
            return failure(CLIError(code: "io_error", message: error.localizedDescription))
        }
    }

    private struct Envelope<Value: Encodable>: Encodable {
        let schemaVersion = 1
        let data: Value
    }
    private struct Failure: Encodable {
        let schemaVersion = 1
        let error: CLIError
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var bytes = try encoder.encode(value)
        bytes.append(10)
        return bytes
    }
    private static func success<T: Encodable>(_ value: T, exitCode: Int32 = 0) throws -> CLIOutput {
        CLIOutput(stdout: try encode(Envelope(data: value)), stderr: Data(), exitCode: exitCode)
    }
    private static func failure(_ error: CLIError) -> CLIOutput {
        // CLIError contains only strings and an integer, so JSON encoding cannot encounter nonfinite values.
        let bytes = (try? encode(Failure(error: error))) ?? Data("{\"error\":{\"code\":\"encoding_error\"}}\n".utf8)
        return CLIOutput(stdout: Data(), stderr: bytes, exitCode: error.exitCode)
    }

    private static func profile(at path: String?) throws -> PrinterProfile {
        guard let path else { return .ender5Pro }
        let profile: PrinterProfile
        do {
            profile = try JSONDecoder().decode(PrinterProfile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw CLIError(code: "profile_input", message: "Cannot load profile at \(path): \(error.localizedDescription)")
        }
        guard profile.minX.isFinite, profile.minY.isFinite, profile.minZ.isFinite,
              profile.maxX.isFinite, profile.maxY.isFinite, profile.maxZ.isFinite,
              profile.minX < profile.maxX, profile.minY < profile.maxY, profile.minZ < profile.maxZ,
              profile.maxHotendTemperature.isFinite, profile.maxHotendTemperature > 0,
              profile.maxBedTemperature.isFinite, profile.maxBedTemperature > 0 else {
            throw CLIError(code: "profile_input", message: "Profile must have ordered finite build bounds and positive finite temperature limits.")
        }
        return profile
    }

    private struct Port: Encodable {
        let path: String
        let kind: String
        let productName: String?
        let score: Int
    }
    private struct Inspection: Encodable {
        let name: String
        let commandCount: Int
        let layerCount: Int
        let metadata: GCodeMetadata
        let profile: PrinterProfile
        let warnings: [GCodeWarning]
        let hasBlockingWarnings: Bool
        let validationScope = "Slicer metadata and recognized temperature commands only; not a motion simulation or safety certification."
    }
    private struct CommandLine: Encodable {
        let index: Int
        let sourceLine: Int
        let command: String
    }
    private struct CommandPage: Encodable {
        let total: Int
        let offset: Int
        let nextOffset: Int?
        let commands: [CommandLine]
    }
    private struct Assessment: Encodable {
        let command: String
        let classification: String
        let requiresConfirmation: Bool
        let reason: String?
        let isEmergency: Bool
        let scope = "Console typo guard only; ordinary does not mean safe to execute."
    }

    private static func execute(_ command: CLICommand) throws -> CLIOutput {
        switch command {
        case .help(let json):
            if json { return try success(["help": help]) }
            return CLIOutput(stdout: Data((help + "\n").utf8), stderr: Data(), exitCode: 0)
        case .version:
            return try success(["version": "1.0.0"])
        case .ports(let includeDialin):
            return try success(SerialPortDiscovery.availablePorts(includeDialin: includeDialin).map {
                Port(path: $0.path, kind: $0.kind.rawValue, productName: $0.productName, score: $0.score)
            })
        case .profile(let path):
            return try success(profile(at: path))
        case .inspect(let path, let profilePath, let validate):
            let machine = try profile(at: profilePath)
            let file = try GCodeFile.load(contentsOf: URL(fileURLWithPath: path))
            let warnings = file.warnings(for: machine)
            let blocked = warnings.contains { $0.severity == .blocking }
            do {
                return try success(Inspection(name: file.name, commandCount: file.commandCount,
                                              layerCount: file.layerCount, metadata: file.metadata,
                                              profile: machine, warnings: warnings, hasBlockingWarnings: blocked),
                                   exitCode: validate && blocked ? 3 : 0)
            } catch is EncodingError {
                throw CLIError(code: "gcode_input", message: "File metadata contains a nonfinite number that cannot be represented in JSON.")
            }
        case .commands(let path, let offset, let limit):
            let file = try GCodeFile.load(contentsOf: URL(fileURLWithPath: path))
            let start = min(offset, file.commandCount)
            let end = start + min(limit, file.commandCount - start)
            let commands = (start..<end).map { index in
                let line = file.commandLineIndices[index]
                return CommandLine(index: index, sourceLine: line + 1, command: MarlinConnection.sanitise(file.lines[line]))
            }
            return try success(CommandPage(total: file.commandCount, offset: offset,
                                           nextOffset: end < file.commandCount ? end : nil, commands: commands))
        case .assess(let raw):
            let cleaned = MarlinConnection.sanitise(raw)
            guard !cleaned.isEmpty else { throw CLIError.usage("The supplied line contains no command.") }
            let risk = CommandSafety.assess(cleaned)
            let reason: String?
            switch risk {
            case .ordinary: reason = nil
            case .dangerous(let explanation): reason = explanation
            }
            return try success(Assessment(command: cleaned, classification: risk.requiresConfirmation ? "dangerous" : "ordinary",
                                          requiresConfirmation: risk.requiresConfirmation, reason: reason,
                                          isEmergency: CommandSafety.isEmergency(cleaned)))
        }
    }
}
