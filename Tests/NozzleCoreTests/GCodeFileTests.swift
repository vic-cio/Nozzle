import Testing
import Foundation
@testable import NozzleCore

/// A miniature stand-in for a Cura file: the same header, two layers, the same footer.
private let curaSample = """
;FLAVOR:Marlin
;TIME:1821
;Filament used: 1.36901m
;Layer height: 0.2
;MINX:89
;MINY:89
;MINZ:0.2
;MAXX:131
;MAXY:131
;MAXZ:20
;TARGET_MACHINE.NAME:Creality Ender-5
;Generated with Cura_SteamEngine 5.13.0
M140 S50
M190 S50
M104 S210
M109 S210

G28 ;Home
G92 E0 ;Reset Extruder
;LAYER_COUNT:2
;LAYER:0
G1 X10 Y20 Z0.3 F1500 E15
G1 X100 Y20 E20
;TIME_ELAPSED:100.0
;LAYER:1
G1 Z0.5
G1 X100 Y100 E25
G1 X10 Y100 E30
;TIME_ELAPSED:300.0
M140 S0
M104 S0
;End of Gcode
"""

@Suite("Reading a sliced file")
struct GCodeFileTests {

    private func sample() throws -> GCodeFile {
        try GCodeFile.parse(curaSample, name: "cube.gcode")
    }

    @Test("Cura's header is read back accurately")
    func metadata() throws {
        let file = try sample()
        let metadata = file.metadata

        #expect(metadata.flavor == "Marlin")
        #expect(metadata.estimatedDuration == 1821)
        #expect(metadata.layerHeight == 0.2)
        #expect(metadata.filamentUsedMetres == 1.36901)
        #expect(metadata.declaredLayerCount == 2)
        #expect(metadata.targetMachine == "Creality Ender-5")
        #expect(metadata.generator == "Cura_SteamEngine 5.13.0")
        #expect(metadata.bounds.maxX == 131)
        #expect(metadata.bounds.minZ == 0.2)
        #expect(metadata.bounds.sizeDescription == "42 × 42 × 19.8 mm")
    }

    @Test("The hottest temperature the file ever asks for is known before printing")
    func temperatures() throws {
        let metadata = try sample().metadata
        #expect(metadata.maxHotendTarget == 210)
        #expect(metadata.maxBedTarget == 50)
    }

    @Test("Comments and blank lines are not commands")
    func commandsOnly() throws {
        let file = try sample()
        // Every indexed line must be something the printer can actually run.
        for index in file.commandLineIndices {
            let line = file.lines[index].trimmingCharacters(in: .whitespaces)
            #expect(!line.isEmpty)
            #expect(!line.hasPrefix(";"))
        }
        #expect(file.commandCount == 13)
    }

    @Test("Layers are found and closed at their own TIME_ELAPSED marker")
    func layers() throws {
        let file = try sample()
        #expect(file.layers.count == 2)
        #expect(file.layers[0].number == 0)
        #expect(file.layers[0].elapsedAtEnd == 100)
        #expect(file.layers[1].elapsedAtEnd == 300)

        // A layer ends where the slicer says its work ends, which is before the next
        // layer starts — not at it.
        #expect(file.lines[file.layers[0].endLineIndex].hasPrefix(";TIME_ELAPSED:"))
        #expect(file.layers[0].endLineIndex < file.layers[1].firstLineIndex)

        // Crucially the last layer stops before the footer, so the file's cool-down and
        // park commands are not counted as printing time.
        #expect(file.layers[1].endLineIndex < file.lines.count - 1)
        #expect(file.lines[file.layers[1].endLineIndex].hasPrefix(";TIME_ELAPSED:"))
    }

    @Test("A file with no commands is rejected rather than printed as nothing")
    func rejectsCommentOnlyFile() {
        #expect(throws: GCodeError.noCommands) {
            try GCodeFile.parse(";just a comment\n;and another", name: "empty.gcode")
        }
    }

    @Test("A file from another slicer still loads, it just knows less about it")
    func plainFile() throws {
        let file = try GCodeFile.parse("G28\nG1 X10 Y10\nM104 S200", name: "hand.gcode")
        #expect(file.commandCount == 3)
        #expect(file.layers.isEmpty)
        #expect(file.metadata.estimatedDuration == nil)
        #expect(file.metadata.homesItself)
        // No timings means no time estimate, rather than a made-up one.
        #expect(file.estimatedRemaining(atLineIndex: 1) == nil)
    }
}

@Suite("Estimating how long is left")
struct GCodeTimingTests {

    private func sample() throws -> GCodeFile {
        try GCodeFile.parse(curaSample, name: "cube.gcode")
    }

    @Test("Time is interpolated inside the layer the slicer already timed")
    func interpolatesWithinLayer() throws {
        let file = try sample()
        let first = file.layers[0]

        // At the start of layer 0, nothing of the print has elapsed.
        #expect(file.estimatedElapsed(atLineIndex: first.firstLineIndex) == 0)

        // Halfway through layer 0's lines is roughly halfway through its 100 seconds.
        let middle = first.firstLineIndex + (first.endLineIndex - first.firstLineIndex) / 2
        let elapsed = try #require(file.estimatedElapsed(atLineIndex: middle))
        #expect(elapsed > 0 && elapsed < 100)
    }

    @Test("Each layer picks up where the previous one finished")
    func layersAreCumulative() throws {
        let file = try sample()
        let second = file.layers[1]
        #expect(file.estimatedElapsed(atLineIndex: second.firstLineIndex) == 100)
    }

    @Test("Remaining time counts down from the slicer's own estimate")
    func remaining() throws {
        let file = try sample()
        let atStart = try #require(file.estimatedRemaining(atLineIndex: 0))
        #expect(atStart == 1821)

        let atSecondLayer = try #require(file.estimatedRemaining(atLineIndex: file.layers[1].firstLineIndex))
        #expect(atSecondLayer == 1721)   // 1821 total − 100 elapsed
    }
}

@Suite("Checking a file against the machine")
struct GCodeWarningTests {

    private let profile = PrinterProfile.ender5Pro

    @Test("The real calibration cube raises nothing blocking")
    func sampleIsFine() throws {
        let file = try GCodeFile.parse(curaSample, name: "cube.gcode")
        let blocking = file.warnings(for: profile).filter { $0.severity == .blocking }
        #expect(blocking.isEmpty, "unexpected: \(blocking.map(\.title))")
    }

    @Test("A print larger than the bed is blocked, and says by how much")
    func tooBig() throws {
        let oversized = curaSample.replacingOccurrences(of: ";MAXX:131", with: ";MAXX:260")
        let file = try GCodeFile.parse(oversized, name: "big.gcode")

        let warning = try #require(file.warnings(for: profile).first { $0.id == "bounds" })
        #expect(warning.severity == .blocking)
        #expect(warning.detail.contains("260"))
        #expect(warning.detail.contains("220"))
    }

    @Test("A file that would over-heat the machine is blocked")
    func tooHot() throws {
        let hot = curaSample.replacingOccurrences(of: "M109 S210", with: "M109 S300")
        let file = try GCodeFile.parse(hot, name: "hot.gcode")

        let warning = try #require(file.warnings(for: profile).first { $0.id == "hotend-temperature" })
        #expect(warning.severity == .blocking)
        #expect(warning.detail.contains("300"))
    }

    @Test("Another firmware's flavour is blocked rather than half-understood")
    func wrongFlavour() throws {
        let other = curaSample.replacingOccurrences(of: ";FLAVOR:Marlin", with: ";FLAVOR:RepRap")
        let file = try GCodeFile.parse(other, name: "reprap.gcode")

        #expect(file.warnings(for: profile).contains { $0.id == "flavour" && $0.severity == .blocking })
    }

    @Test("A file that never homes is flagged, but not blocked")
    func noHoming() throws {
        let file = try GCodeFile.parse("G1 X10 Y10 E5", name: "fragment.gcode")
        let warning = try #require(file.warnings(for: profile).first { $0.id == "no-homing" })
        #expect(warning.severity == .advisory)
    }
}
