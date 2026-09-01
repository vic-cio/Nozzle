import Testing
import Foundation
@testable import NozzleCore

@Suite("Temperature parsing")
struct TemperatureParsingTests {
    let parser = MarlinResponseParser()

    @Test("Standard M105 reply with spaced targets")
    func standardReply() throws {
        let response = parser.parse("ok T:199.8 /200.0 B:59.7 /60.0 @:127 B@:0")
        guard case .ok(let info) = response else { Issue.record("expected ok"); return }
        let temperature = try #require(info.temperature)
        #expect(temperature.hotend?.current == 199.8)
        #expect(temperature.hotend?.target == 200.0)
        #expect(temperature.bed?.current == 59.7)
        #expect(temperature.bed?.target == 60.0)
        #expect(temperature.hotendPower == 127)
        #expect(temperature.bedPower == 0)
    }

    @Test("Targets written without a space still parse")
    func inlineTargets() throws {
        let report = try #require(parser.parseTemperature("T:24.31/0.00 B:23.50/0.00"))
        #expect(report.hotend?.current == 24.31)
        #expect(report.hotend?.target == 0)
        #expect(report.bed?.target == 0)
    }

    @Test("Autoreport line with no ok is recognised as a temperature")
    func autoreport() throws {
        let response = parser.parse(" T:22.50 /0.00 B:22.00 /0.00 @:0 B@:0")
        guard case .temperature(let report) = response else {
            Issue.record("expected a bare temperature report, got \(response)")
            return
        }
        #expect(report.hotend?.current == 22.5)
    }

    @Test("Multiple extruders land in separate slots")
    func multipleHotends() throws {
        let report = try #require(parser.parseTemperature("ok T0:200.0 /200.0 T1:180.0 /180.0 B:60.0 /60.0"))
        #expect(report.hotends[0]?.current == 200)
        #expect(report.hotends[1]?.current == 180)
        #expect(report.bed?.current == 60)
    }

    @Test("A wait marker with no numeric value is ignored, not misparsed")
    func waitMarker() throws {
        let report = try #require(parser.parseTemperature("T:150.0 /200.0 B:40.0 /60.0 @:127 B@:127 W:?"))
        #expect(report.hotend?.target == 200)
        #expect(report.bed?.current == 40)
    }

    @Test("ADVANCED_OK buffer counts are never mistaken for a bed temperature")
    func advancedOkIsNotABedTemperature() throws {
        // `B4` means "4 free buffer slots". `B:4` would mean "the bed is at 4 °C".
        // Confusing the two would make the UI report an absurd bed temperature.
        let response = parser.parse("ok N42 P15 B4")
        guard case .ok(let info) = response else { Issue.record("expected ok"); return }
        #expect(info.lineNumber == 42)
        #expect(info.plannerFree == 15)
        #expect(info.bufferFree == 4)
        #expect(info.temperature == nil)
    }

    @Test("ADVANCED_OK and a temperature payload can coexist")
    func advancedOkWithTemperature() throws {
        let response = parser.parse("ok N42 P15 B4 T:199.8 /200.0 B:59.7 /60.0")
        guard case .ok(let info) = response else { Issue.record("expected ok"); return }
        #expect(info.bufferFree == 4)
        #expect(info.temperature?.bed?.current == 59.7)
    }
}

@Suite("Acknowledgement parsing")
struct AcknowledgementTests {
    let parser = MarlinResponseParser()

    @Test("Bare ok")
    func bareOk() {
        #expect(parser.parse("ok").isAcknowledgement)
        #expect(parser.parse("ok ").isAcknowledgement)
    }

    @Test("Words beginning with ok are not acknowledgements")
    func notAnOk() {
        #expect(!parser.parse("okay then").isAcknowledgement)
        #expect(!parser.parse("okto").isAcknowledgement)
    }

    @Test("busy keepalive is not an acknowledgement")
    func busyIsNotOk() {
        #expect(parser.parse("echo:busy: processing") == .busy)
        #expect(!parser.parse("echo:busy: processing").isAcknowledgement)
    }

    @Test("Boot banner")
    func start() {
        #expect(parser.parse("start") == .start)
    }

    @Test("Error lines")
    func errors() {
        #expect(parser.parse("Error:Printer halted. kill() called!") == .error("Printer halted. kill() called!"))
    }

    @Test("Host action commands")
    func actions() {
        #expect(parser.parse("//action:paused") == .action("paused"))
    }
}

@Suite("Resend parsing")
struct ResendParsingTests {
    let parser = MarlinResponseParser()

    @Test("Resend: N", arguments: [
        ("Resend: 380", 380),
        ("Resend:380", 380),
        ("resend: 12", 12),
        ("rs 42", 42),
    ])
    func variants(input: String, expected: Int) {
        #expect(parser.parse(input) == .resend(line: expected))
    }

    @Test("A checksum error line on its own is an error, not a resend")
    func errorLineIsNotAResend() {
        #expect(parser.parse("Error:checksum mismatch, Last Line: 385")
                == .error("checksum mismatch, Last Line: 385"))
    }
}

@Suite("Firmware info parsing")
struct FirmwareInfoTests {
    let parser = MarlinResponseParser()

    @Test("Full M115 identification line")
    func fullLine() {
        let line = "FIRMWARE_NAME:Marlin 2.0.8.2 (Github) SOURCE_CODE_URL:https://github.com/MarlinFirmware/Marlin "
                 + "PROTOCOL_VERSION:1.0 MACHINE_TYPE:Ender-5 Pro EXTRUDER_COUNT:1 UUID:cede2a2f-41a2"
        let info = parser.parseFirmwareInfo(line)
        #expect(info.firmwareName == "Marlin 2.0.8.2 (Github)")
        // Values containing spaces must survive; splitting on whitespace would truncate this.
        #expect(info.machineType == "Ender-5 Pro")
        // A lowercase "https:" must not be treated as the start of a new field.
        #expect(info.sourceCodeURL == "https://github.com/MarlinFirmware/Marlin")
        #expect(info.protocolVersion == "1.0")
        #expect(info.extruderCount == 1)
        #expect(info.uuid == "cede2a2f-41a2")
    }

    @Test("Capability lines")
    func capabilities() {
        #expect(parser.parse("Cap:EEPROM:1") == .capability(name: "EEPROM", enabled: true))
        #expect(parser.parse("Cap:AUTOREPORT_TEMP:0") == .capability(name: "AUTOREPORT_TEMP", enabled: false))
    }

    @Test("Capability lookup by known capability")
    func capabilityLookup() {
        var info = FirmwareInfo()
        info.capabilities["EMERGENCY_PARSER"] = true
        #expect(info.supports(.emergencyParser))
        #expect(!info.supports(.autoreportTemperature))
    }
}

@Suite("Position parsing")
struct PositionParsingTests {
    let parser = MarlinResponseParser()

    @Test("M114 reply, discarding stepper counts")
    func m114() throws {
        let response = parser.parse("X:10.00 Y:20.00 Z:0.30 E:0.00 Count X:800 Y:1600 Z:120")
        guard case .position(let position) = response else { Issue.record("expected position"); return }
        #expect(position.x == 10)
        #expect(position.y == 20)
        #expect(position.z == 0.3)
        // The Count block is stepper counts, not millimetres — it must not overwrite X/Y/Z.
        #expect(position.e == 0)
    }
}

@Suite("Checksums")
struct ChecksumTests {
    @Test("XOR checksum matches Marlin's algorithm")
    func knownValues() {
        // Reference values computed the way Marlin does: XOR every byte of "N<line><command>".
        func reference(_ text: String) -> UInt8 {
            text.utf8.reduce(UInt8(0)) { $0 ^ $1 }
        }
        for payload in ["N1M115", "N0M110 N0", "N42G1 X10.5 Y20 E1.2 F1500"] {
            #expect(MarlinConnection.checksum(of: payload) == reference(payload))
        }
    }

    @Test("Comments are stripped before transmission")
    func sanitising() {
        #expect(MarlinConnection.sanitise("G1 X10 ; move right") == "G1 X10")
        #expect(MarlinConnection.sanitise("  M105  ") == "M105")
        #expect(MarlinConnection.sanitise("; only a comment").isEmpty)
    }
}

@Suite("Line assembly")
struct LineAssemblerTests {

    @Test("A response split across two reads still yields one line")
    func splitAcrossReads() {
        var assembler = LineAssembler()
        #expect(assembler.append(Array("ok T:199".utf8)).isEmpty)
        let lines = assembler.append(Array(".8 /200.0\n".utf8))
        #expect(lines == ["ok T:199.8 /200.0"])
    }

    @Test("Several lines in one read")
    func multipleLines() {
        var assembler = LineAssembler()
        #expect(assembler.append(Array("start\nok\nok\n".utf8)) == ["start", "ok", "ok"])
    }

    @Test("Carriage returns are dropped")
    func carriageReturns() {
        var assembler = LineAssembler()
        #expect(assembler.append(Array("ok\r\n".utf8)) == ["ok"])
    }

    @Test("An endless line is cut rather than growing without bound")
    func overlongLine() {
        var assembler = LineAssembler(maxLineLength: 16)
        let lines = assembler.append(Array(String(repeating: "x", count: 40).utf8))
        #expect(lines.count == 2)
        #expect(lines[0].count == 16)
    }
}

@Suite("Command safety")
struct CommandSafetyTests {

    @Test("Destructive commands need confirmation", arguments: ["M112", "M502", "M851 Z-1.2", "G29"])
    func dangerous(command: String) {
        #expect(CommandSafety.assess(command).requiresConfirmation)
    }

    @Test("Everyday commands do not", arguments: ["M105", "M115", "G28", "G1 X10", "M114", "M503"])
    func ordinary(command: String) {
        #expect(!CommandSafety.assess(command).requiresConfirmation)
    }

    @Test("Matching is on the whole code, not a prefix")
    func prefixesDoNotBleed() {
        // M11 must not inherit M112's warning.
        #expect(!CommandSafety.assess("M11").requiresConfirmation)
        #expect(CommandSafety.assess("M112").requiresConfirmation)
    }

    @Test("Emergency commands are identified for immediate dispatch")
    func emergency() {
        #expect(CommandSafety.isEmergency("M112"))
        #expect(CommandSafety.isEmergency("M410"))
        #expect(!CommandSafety.isEmergency("M105"))
    }
}
