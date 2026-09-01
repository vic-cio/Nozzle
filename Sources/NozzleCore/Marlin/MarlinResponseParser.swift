import Foundation

/// Turns one line of Marlin output into a `MarlinResponse`.
///
/// Deliberately a pure, stateless value type: every branch here is unit-testable
/// with a string literal and no printer, no port and no actor.
///
/// Hand-written tokenising rather than regular expressions — the formats are simple,
/// and the awkward cases (`ok N1 P15 B4` vs `ok B:59.7 /60.0`, where `B` means two
/// completely different things) are clearer to disambiguate explicitly.
public struct MarlinResponseParser: Sendable {

    public init() {}

    public func parse(_ rawLine: String) -> MarlinResponse {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .unknown("") }

        // Order matters: `ok` first because it is the hot path and frees a queue slot.
        if isOk(line) {
            return .ok(parseOk(line))
        }

        if let resendLine = parseResend(line) {
            return .resend(line: resendLine)
        }

        let lower = line.lowercased()

        if lower == "start" || lower == "start." {
            return .start
        }
        if lower == "wait" {
            return .wait
        }
        if lower.contains("busy:") {
            return .busy
        }
        if line.hasPrefix("//action:") {
            return .action(String(line.dropFirst("//action:".count)))
        }
        if line.hasPrefix("Cap:") {
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3 {
                return .capability(name: String(parts[1]), enabled: parts[2].trimmingCharacters(in: .whitespaces) == "1")
            }
            return .unknown(line)
        }
        if lower.hasPrefix("error:") || lower.hasPrefix("!!") {
            let message = line.contains(":")
                ? String(line.drop(while: { $0 != ":" }).dropFirst())
                : line
            return .error(message.trimmingCharacters(in: .whitespaces))
        }
        if line.contains("FIRMWARE_NAME:") {
            return .firmware(parseFirmwareInfo(line))
        }
        if let position = parsePosition(line) {
            return .position(position)
        }
        // An unsolicited temperature line: the reply to M105 arrives on the `ok`,
        // but `M155` autoreports arrive bare, as ` T:22.5 /0.0 B:22.0 /0.0 @:0 B@:0`.
        if let temperature = parseTemperature(line), !temperature.isEmpty {
            return .temperature(temperature)
        }
        if line.hasPrefix("echo:") {
            return .echo(String(line.dropFirst("echo:".count)).trimmingCharacters(in: .whitespaces))
        }

        return .unknown(line)
    }

    // MARK: - ok

    private func isOk(_ line: String) -> Bool {
        guard line.hasPrefix("ok") else { return false }
        if line.count == 2 { return true }
        // Guard against a hypothetical word starting with "ok".
        let next = line[line.index(line.startIndex, offsetBy: 2)]
        return !next.isLetter && !next.isNumber
    }

    /// Parses `ok`, `ok N12 P15 B4` (ADVANCED_OK) and `ok T:199.8 /200.0 B:59.7 /60.0`.
    public func parseOk(_ line: String) -> OkInfo {
        var info = OkInfo()

        // ADVANCED_OK fields have no colon (`B4`); temperature fields always do (`B:59.7`).
        // That single distinction is what keeps buffer counts and bed temperatures apart.
        for token in line.split(separator: " ") where !token.contains(":") {
            guard let first = token.first, token.count > 1 else { continue }
            let number = Int(token.dropFirst())
            switch first {
            case "N": info.lineNumber = number
            case "P": info.plannerFree = number
            case "B": info.bufferFree = number
            default: break
            }
        }

        if let temperature = parseTemperature(line), !temperature.isEmpty {
            info.temperature = temperature
        }
        return info
    }

    // MARK: - Resend

    /// Recognises `Resend: 380`, `Resend:380` and the legacy `rs 380`.
    public func parseResend(_ line: String) -> Int? {
        let lower = line.lowercased()
        let marker: String
        if let range = lower.range(of: "resend") {
            marker = String(line[range.upperBound...])
        } else if lower.hasPrefix("rs ") || lower.hasPrefix("rs:") {
            marker = String(line.dropFirst(2))
        } else {
            return nil
        }
        return firstInteger(in: marker)
    }

    private func firstInteger(in text: String) -> Int? {
        var digits = ""
        var started = false
        for character in text {
            if character.isNumber {
                digits.append(character)
                started = true
            } else if started {
                break
            }
        }
        return Int(digits)
    }

    // MARK: - Temperatures

    /// Parses the `T:`/`B:`/`C:`/`@:` token soup shared by `M105` replies and autoreports.
    ///
    /// Handles both spacings Marlin and its forks emit:
    /// `T:199.8 /200.0` (target as its own token) and `T:199.8/200.0`.
    public func parseTemperature(_ line: String) -> TemperatureReport? {
        var report = TemperatureReport()
        var pendingKey: String?
        var found = false

        for token in line.split(separator: " ", omittingEmptySubsequences: true) {
            // A bare `/200.0` supplies the target for the key we just saw.
            if token.hasPrefix("/") {
                if let key = pendingKey, let target = Double(token.dropFirst()) {
                    applyTarget(target, forKey: key, to: &report)
                }
                pendingKey = nil
                continue
            }

            guard let colonIndex = token.firstIndex(of: ":") else {
                pendingKey = nil
                continue
            }

            let key = String(token[token.startIndex..<colonIndex])
            var value = String(token[token.index(after: colonIndex)...])
            guard isTemperatureKey(key) else { pendingKey = nil; continue }

            var inlineTarget: Double?
            if let slash = value.firstIndex(of: "/") {
                inlineTarget = Double(value[value.index(after: slash)...])
                value = String(value[value.startIndex..<slash])
            }

            // `W:?` during an M109 wait, and similar — not a number, not our problem.
            guard let current = Double(value) else { pendingKey = nil; continue }

            applyCurrent(current, forKey: key, to: &report)
            found = true
            if let inlineTarget {
                applyTarget(inlineTarget, forKey: key, to: &report)
                pendingKey = nil
            } else {
                pendingKey = key
            }
        }

        return found ? report : nil
    }

    private func isTemperatureKey(_ key: String) -> Bool {
        if key == "B" || key == "C" || key == "T" || key == "@" || key == "B@" { return true }
        // T0, T1, ...
        if key.hasPrefix("T"), key.count > 1, Int(key.dropFirst()) != nil { return true }
        return false
    }

    private func applyCurrent(_ value: Double, forKey key: String, to report: inout TemperatureReport) {
        switch key {
        case "T":
            report.hotends[0] = HeaterTemperature(current: value, target: report.hotends[0]?.target)
        case "B":
            report.bed = HeaterTemperature(current: value, target: report.bed?.target)
        case "C":
            report.chamber = HeaterTemperature(current: value, target: report.chamber?.target)
        case "@":
            report.hotendPower = Int(value)
        case "B@":
            report.bedPower = Int(value)
        default:
            if let index = Int(key.dropFirst()) {
                report.hotends[index] = HeaterTemperature(current: value, target: report.hotends[index]?.target)
            }
        }
    }

    private func applyTarget(_ value: Double, forKey key: String, to report: inout TemperatureReport) {
        switch key {
        case "T":
            report.hotends[0]?.target = value
        case "B":
            report.bed?.target = value
        case "C":
            report.chamber?.target = value
        case "@", "B@":
            break   // PWM duty has no target
        default:
            if let index = Int(key.dropFirst()) { report.hotends[index]?.target = value }
        }
    }

    // MARK: - Position

    /// Parses `X:0.00 Y:0.00 Z:0.00 E:0.00 Count X:0 Y:0 Z:0`.
    ///
    /// The `Count ...` suffix is stepper counts, not millimetres, and is discarded —
    /// showing it as a coordinate would be actively misleading.
    public func parsePosition(_ line: String) -> PositionReport? {
        guard line.hasPrefix("X:"), line.contains("Y:") else { return nil }

        var scope = line
        if let countRange = scope.range(of: "Count") {
            scope = String(scope[scope.startIndex..<countRange.lowerBound])
        }

        var report = PositionReport()
        for token in scope.split(separator: " ") {
            guard let colonIndex = token.firstIndex(of: ":") else { continue }
            let key = String(token[token.startIndex..<colonIndex])
            guard let value = Double(token[token.index(after: colonIndex)...]) else { continue }
            switch key {
            case "X": report.x = value
            case "Y": report.y = value
            case "Z": report.z = value
            case "E": report.e = value
            default: break
            }
        }
        return (report.x != nil && report.y != nil) ? report : nil
    }

    // MARK: - Firmware info

    /// Parses the `M115` identification line.
    ///
    /// Values may contain spaces (`MACHINE_TYPE:Ender-5 Pro`), so fields are split on
    /// SHOUTING_KEY: boundaries rather than on whitespace. A lowercase prefix such as
    /// the `https:` inside `SOURCE_CODE_URL` therefore does not start a new field.
    public func parseFirmwareInfo(_ line: String) -> FirmwareInfo {
        var info = FirmwareInfo(rawLines: [line])
        for (key, value) in keyedFields(line) {
            switch key {
            case "FIRMWARE_NAME":   info.firmwareName = value
            case "MACHINE_TYPE":    info.machineType = value
            case "PROTOCOL_VERSION":info.protocolVersion = value
            case "SOURCE_CODE_URL": info.sourceCodeURL = value
            case "EXTRUDER_COUNT":  info.extruderCount = Int(value)
            case "UUID":            info.uuid = value
            default: break
            }
        }
        return info
    }

    private func keyedFields(_ line: String) -> [(key: String, value: String)] {
        var fields: [(String, String)] = []
        var currentKey: String?
        var currentValue: [String] = []

        func flush() {
            if let key = currentKey {
                fields.append((key, currentValue.joined(separator: " ").trimmingCharacters(in: .whitespaces)))
            }
            currentValue = []
        }

        for word in line.split(separator: " ") {
            if let colonIndex = word.firstIndex(of: ":") {
                let candidate = String(word[word.startIndex..<colonIndex])
                if isShoutingKey(candidate) {
                    flush()
                    currentKey = candidate
                    currentValue = [String(word[word.index(after: colonIndex)...])]
                    continue
                }
            }
            currentValue.append(String(word))
        }
        flush()
        return fields
    }

    /// `FIRMWARE_NAME` yes, `https` no.
    private func isShoutingKey(_ candidate: String) -> Bool {
        guard candidate.count >= 3 else { return false }
        var hasLetter = false
        for character in candidate {
            if character.isUppercase { hasLetter = true; continue }
            if character.isNumber || character == "_" { continue }
            return false
        }
        return hasLetter
    }
}
