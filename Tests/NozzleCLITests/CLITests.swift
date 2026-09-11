import Foundation
import Testing
@testable import NozzleCLIKit

@Suite("Nozzle CLI")
struct CLITests {
    @Test func parsesSurface() throws {
        #expect(try CLICommand.parse([]) == .help(json: false))
        #expect(try CLICommand.parse(["file", "inspect", "cube.gcode", "--profile", "machine.json"]) == .inspect(path: "cube.gcode", profile: "machine.json", validate: false))
        #expect(try CLICommand.parse(["--json", "ports", "--include-dialin"]) == .ports(includeDialin: true))
        #expect(try CLICommand.parse(["profile", "show"]) == .profile(path: nil))
        #expect(try CLICommand.parse(["file", "commands", "--", "-cube.gcode"]) == .commands(path: "-cube.gcode", offset: 0, limit: 100))
        #expect(try CLICommand.parse(["file", "validate", "cube.gcode"]) == .inspect(path: "cube.gcode", profile: nil, validate: true))
    }

    @Test(arguments: [
        ["unknown"], ["ports", "extra"], ["ports", "--profile", "x"],
        ["file", "inspect"], ["file", "inspect", "a", "b"],
        ["file", "inspect", "a", "--profile"], ["ports", "--wat"],
        ["file", "commands", "a", "--offset", "-1"],
        ["file", "commands", "a", "--limit", "1001"],
        ["file", "commands", "a", "--limit", "x"],
        ["file", "commands", "a", "--limit", "2", "--limit", "3"],
        ["command", "assess", "G28\nM112"], ["command", "assess", " "],
        ["ports", "--version"], ["--json"],
    ])
    func rejectsBadArguments(arguments: [String]) throws {
        let result = CLIRunner.run(arguments)
        #expect(result.exitCode == 2)
        #expect(result.stdout.isEmpty)
        let body = try JSONSerialization.jsonObject(with: result.stderr) as? [String: Any]
        #expect((body?["error"] as? [String: Any])?["code"] as? String == "usage")
    }

    private func withFile(_ content: String, _ body: (String) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url.path)
    }
    private func data(_ result: CLIOutput) throws -> [String: Any] {
        let object = try #require(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        return try #require(object["data"] as? [String: Any])
    }

    @Test func inspectionAndValidation() throws {
        try withFile(";FLAVOR:Marlin\n;TIME:123\n;MAXX:221\n;MAXY:20\n;MAXZ:2\nG28\nM104 S280") { path in
            let inspection = CLIRunner.run(["file", "inspect", path])
            #expect(inspection.exitCode == 0)
            let result = try data(inspection)
            #expect(result["commandCount"] as? Int == 2)
            #expect(result["hasBlockingWarnings"] as? Bool == true)
            #expect((result["metadata"] as? [String: Any])?["estimatedDuration"] as? Int == 123)
            let validation = CLIRunner.run(["file", "validate", path])
            #expect(validation.exitCode == 3)
            #expect(validation.stderr.isEmpty)
            #expect(validation.stdout == inspection.stdout)
            let warnings = try #require(result["warnings"] as? [[String: Any]])
            #expect(warnings.compactMap { $0["id"] as? String } == ["bounds", "hotend-temperature"])
        }
    }
    @Test func advisoryIsNotBlocking() throws {
        try withFile("G1 X20") { path in
            let result = CLIRunner.run(["file", "validate", path])
            #expect(result.exitCode == 0)
            let report = try data(result)
            #expect(report["hasBlockingWarnings"] as? Bool == false)
        }
    }
    @Test func commandPagesPreserveSourceLines() throws {
        try withFile(";Header\nG28 ; home\n\nG1 X20\nM104 S0") { path in
            let result = try data(CLIRunner.run(["file", "commands", path, "--offset", "1", "--limit", "1"]))
            let lines = try #require(result["commands"] as? [[String: Any]])
            #expect(lines.count == 1)
            #expect(lines[0]["sourceLine"] as? Int == 4)
            #expect(lines[0]["command"] as? String == "G1 X20")
            #expect(result["nextOffset"] as? Int == 2)
            let beyond = try data(CLIRunner.run(["file", "commands", path, "--offset", String(Int.max)]))
            #expect((beyond["commands"] as? [Any])?.isEmpty == true)
            #expect(beyond["nextOffset"] == nil)
        }
    }
    @Test func profilesAreExplicitAndStrict() throws {
        try withFile("{\"maxX\":250}") { path in
            let profile = try data(CLIRunner.run(["profile", "show", "--profile", path]))
            #expect(profile["maxX"] as? Int == 250)
            #expect(profile["maxY"] as? Int == 220)
        }
        for text in ["{", "{\"maxX\":-1}", "{\"maxBedTemperature\":0}"] {
            try withFile(text) { path in
                #expect(CLIRunner.run(["profile", "show", "--profile", path]).exitCode == 1)
            }
        }
        #expect(CLIRunner.run(["profile", "show", "--profile", "/nonexistent/nozzle-profile.json"]).exitCode == 1)
    }
    @Test func classifiesWithoutExecuting() throws {
        let risk = try data(CLIRunner.run(["command", "assess", "m112 ; stop"]))
        #expect(risk["classification"] as? String == "dangerous")
        #expect(risk["isEmergency"] as? Bool == true)
        let ordinary = try data(CLIRunner.run(["command", "assess", "M105"]))
        #expect(ordinary["requiresConfirmation"] as? Bool == false)
        #expect(CLIRunner.run(["command", "assess", "; comment"]).exitCode == 2)
    }
    @Test func malformedFilesAndNonfiniteMetadataAreStructuredErrors() throws {
        for content in ["", "; Only comments", ";TIME:nan\nG28"] {
            try withFile(content) { path in
                let result = CLIRunner.run(["file", "inspect", path])
                #expect(result.exitCode == 1)
                #expect(result.stdout.isEmpty)
                let error = try JSONSerialization.jsonObject(with: result.stderr) as? [String: Any]
                #expect((error?["error"] as? [String: Any])?["code"] as? String == "gcode_input")
            }
        }
    }
    @Test func deterministicAndDiscoverable() throws {
        #expect(CLIRunner.run(["profile", "show"]).stdout == CLIRunner.run(["profile", "show"]).stdout)
        #expect(try data(CLIRunner.run(["--help", "--json"]))["help"] as? String == CLIRunner.help)
        #expect(try data(CLIRunner.run(["--version"]))["version"] as? String == "1.0.0")
        #expect(String(decoding: CLIRunner.run(["file", "--help"]).stdout, as: UTF8.self).contains("file validate"))
    }

    @Test func liveStatusReportsWhenTheAppIsUnavailable() throws {
        let missingSocket = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        let result = CLIRunner.run(["live", "status", "--socket", missingSocket])

        #expect(result.exitCode == 1)
        #expect(result.stdout.isEmpty)
        let body = try JSONSerialization.jsonObject(with: result.stderr) as? [String: Any]
        #expect((body?["error"] as? [String: Any])?["code"] as? String == "app_unavailable")
    }

    @Test(arguments: [
        ["live", "connect"],
        ["live", "disconnect"],
        ["live", "home"],
        ["live", "home", "--axes", "XZ"],
        ["live", "jog", "X", "5"],
        ["live", "heat", "nozzle", "210"],
        ["live", "heat", "bed", "60"],
        ["live", "extrude", "5"],
        ["live", "heaters-off"],
        ["live", "motors-off"],
        ["live", "send", "M105"],
        ["live", "send", "M112", "--confirm-dangerous"],
    ])
    func liveCommandsReachTheAppBoundary(arguments: [String]) throws {
        let missingSocket = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        let result = CLIRunner.run(arguments + ["--socket", missingSocket])
        let body = try JSONSerialization.jsonObject(with: result.stderr) as? [String: Any]

        #expect(result.exitCode == 1)
        #expect((body?["error"] as? [String: Any])?["code"] as? String == "app_unavailable")
    }

    @Test(arguments: [
        ["live", "home", "--axes", "Q"],
        ["live", "jog", "Q", "5"],
        ["live", "jog", "X", "nan"],
        ["live", "heat", "chamber", "50"],
        ["live", "heat", "nozzle", "infinity"],
        ["live", "extrude", "0"],
        ["live", "send", "M112"],
    ])
    func liveCommandsRejectUnsafeOrMalformedArguments(arguments: [String]) throws {
        let result = CLIRunner.run(arguments)
        let body = try JSONSerialization.jsonObject(with: result.stderr) as? [String: Any]

        #expect(result.exitCode == 2)
        #expect((body?["error"] as? [String: Any])?["code"] as? String == "usage")
    }
}
