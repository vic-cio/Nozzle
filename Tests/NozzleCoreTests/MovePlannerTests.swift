import Testing
import Foundation
@testable import NozzleCore

/// The layer that decides how far the nozzle is allowed to move. Every case here is a
/// string comparison — no printer, no port, no clock.
@Suite("Move planning")
struct MovePlannerTests {

    private let profile = PrinterProfile.ender5Pro

    // MARK: Homing

    @Test("Homing everything is a bare G28")
    func homeAll() {
        #expect(MovePlanner.home([]).commands == ["G28"])
        #expect(MovePlanner.home(Set(PrinterAxis.allCases)).commands == ["G28"])
    }

    @Test("Homing named axes lists them in X Y Z order")
    func homeSomeAxes() {
        #expect(MovePlanner.home([.y, .x]).commands == ["G28 X Y"])
        #expect(MovePlanner.home([.z]).commands == ["G28 Z"])
    }

    // MARK: Bed levelling shortcuts

    @Test("Levelling points are 30 mm inside each Ender-5 bed corner")
    func bedLevelPointsUseThirtyMillimetreInset() {
        #expect(MovePlanner.bedLevelPoints(profile: profile) == [
            BedLevelPoint(corner: .frontLeft, x: 30, y: 30),
            BedLevelPoint(corner: .frontRight, x: 190, y: 30),
            BedLevelPoint(corner: .rearRight, x: 190, y: 190),
            BedLevelPoint(corner: .rearLeft, x: 30, y: 190),
        ])
    }

    @Test("A levelling shortcut moves X before Y and never moves Z")
    func bedLevelMoveClearsSideClipsWithoutChangingZ() throws {
        let plan = try #require(MovePlanner.moveToBedLevelCorner(
            .rearRight,
            from: PositionReport(x: 0, y: 110, z: 0.1),
            profile: profile
        ).plan)

        #expect(plan.commands == [
            "G90",
            "G0 X190 F3000",
            "G0 Y190 F3000",
            "M400",
            "M114",
        ])
        #expect(plan.commands.contains(where: { $0.contains("Z") }) == false)
    }

    @Test("Levelling points remain inside a small or offset build volume")
    func bedLevelPointsClampInset() {
        var small = profile
        small.minX = -10; small.maxX = 30
        small.minY = 20; small.maxY = 70

        let points = MovePlanner.bedLevelPoints(profile: small)
        #expect(points.allSatisfy { small.isWithinBounds(x: $0.x, y: $0.y, z: nil) })
        #expect(points.first == BedLevelPoint(corner: .frontLeft, x: 10, y: 45))
    }

    @Test("A levelling shortcut requires a known X/Y position")
    func bedLevelMoveNeedsPosition() {
        let result = MovePlanner.moveToBedLevelCorner(.frontLeft, from: nil, profile: profile)
        #expect(result.plan == nil)
        #expect(result.refusal?.contains("Home") == true)
    }

    // MARK: Jogging

    @Test("A jog is a relative move wrapped back into absolute mode")
    func jogIsRelative() throws {
        let position = PositionReport(x: 100, y: 100, z: 10)
        let plan = try #require(MovePlanner.jog(axis: .x, millimetres: 10, from: position, profile: profile).plan)

        // The G90 at the end matters more than it looks: leaving the printer in relative
        // mode would make the next absolute move go somewhere nobody asked for.
        #expect(plan.commands == ["G91", "G0 X10 F3000", "G90"])
        #expect(plan.note == nil)
    }

    @Test("Z jogs use the slower leadscrew feedrate")
    func zUsesItsOwnFeedrate() throws {
        let position = PositionReport(x: 0, y: 0, z: 10)
        let plan = try #require(MovePlanner.jog(axis: .z, millimetres: -1, from: position, profile: profile).plan)
        #expect(plan.commands[1] == "G0 Z-1 F600")
    }

    @Test("Fractional steps keep their precision without trailing zeros")
    func fractionalStep() throws {
        let position = PositionReport(x: 0, y: 0, z: 5)
        let plan = try #require(MovePlanner.jog(axis: .z, millimetres: 0.1, from: position, profile: profile).plan)
        #expect(plan.commands[1] == "G0 Z0.1 F600")
    }

    @Test("Jogging without a known position is refused, not guessed")
    func refusesWithoutPosition() {
        let result = MovePlanner.jog(axis: .x, millimetres: 10, from: nil, profile: profile)
        #expect(result.plan == nil)
        #expect(result.refusal?.contains("does not know where") == true)
    }

    @Test("A move past the edge of the bed is shortened, and says so")
    func clampsToBuildVolume() throws {
        // 215 + 10 would be 225 on a 220 mm axis.
        let position = PositionReport(x: 215, y: 100, z: 10)
        let result = MovePlanner.jog(axis: .x, millimetres: 10, from: position, profile: profile)
        let plan = try #require(result.plan)

        #expect(plan.commands[1] == "G0 X5 F3000")
        let note = try #require(plan.note)
        #expect(note.contains("220"))
        #expect(note.contains("5 mm"))
    }

    @Test("A move below zero is shortened the same way")
    func clampsAtTheLowEnd() throws {
        let position = PositionReport(x: 3, y: 100, z: 10)
        let plan = try #require(MovePlanner.jog(axis: .x, millimetres: -10, from: position, profile: profile).plan)
        #expect(plan.commands[1] == "G0 X-3 F3000")
        #expect(plan.note != nil)
    }

    @Test("An axis already at its limit is refused rather than sent a zero move")
    func refusesAtTheLimit() {
        let position = PositionReport(x: 220, y: 100, z: 10)
        let result = MovePlanner.jog(axis: .x, millimetres: 10, from: position, profile: profile)
        #expect(result.plan == nil)
        #expect(result.refusal?.contains("already at") == true)

        // …but moving away from the limit is still fine.
        #expect(MovePlanner.jog(axis: .x, millimetres: -10, from: position, profile: profile).plan != nil)
    }

    @Test("A zero-millimetre jog does nothing")
    func refusesZero() {
        let position = PositionReport(x: 10, y: 10, z: 10)
        #expect(MovePlanner.jog(axis: .x, millimetres: 0, from: position, profile: profile).plan == nil)
    }

    // MARK: Extrusion

    @Test("Extruding uses relative E and puts it back to absolute")
    func extrudeIsRelative() throws {
        let plan = try #require(MovePlanner.extrude(millimetres: 5, profile: profile).plan)
        // M82 at the end because stock Marlin boots absolute, and a Cura file's header
        // is written expecting to find it that way.
        #expect(plan.commands == ["M83", "G1 E5 F300", "M82"])
    }

    @Test("Retracting is the same command with a negative distance")
    func retract() throws {
        let plan = try #require(MovePlanner.extrude(millimetres: -10, profile: profile).plan)
        #expect(plan.commands[1] == "G1 E-10 F300")
    }

    @Test("An absurd amount of filament is refused")
    func refusesHugeExtrusion() {
        let result = MovePlanner.extrude(millimetres: 5000, profile: profile)
        #expect(result.plan == nil)
        #expect(result.refusal?.contains("200") == true)
    }

    // MARK: Heaters

    @Test("Setting a heater never uses the blocking form")
    func heatersDoNotBlock() throws {
        // M109/M190 would hold the command queue for minutes, during which the user
        // could not even turn the heater back off.
        let nozzle = try #require(MovePlanner.setTemperature(.hotend, celsius: 210, profile: profile).plan)
        let bed = try #require(MovePlanner.setTemperature(.bed, celsius: 60, profile: profile).plan)

        #expect(nozzle.commands == ["M104 S210"])
        #expect(bed.commands == ["M140 S60"])
    }

    @Test("Zero turns a heater off")
    func heaterOff() throws {
        #expect(try #require(MovePlanner.setTemperature(.hotend, celsius: 0, profile: profile).plan).commands == ["M104 S0"])
        #expect(MovePlanner.heatersOff().commands == ["M104 S0", "M140 S0"])
    }

    @Test("A target above the profile's limit is refused")
    func refusesTooHot() {
        let nozzle = MovePlanner.setTemperature(.hotend, celsius: 300, profile: profile)
        #expect(nozzle.plan == nil)
        #expect(nozzle.refusal?.contains("260") == true)

        let bed = MovePlanner.setTemperature(.bed, celsius: 150, profile: profile)
        #expect(bed.plan == nil)
        #expect(bed.refusal?.contains("110") == true)
    }

    @Test("A negative target is refused")
    func refusesNegative() {
        #expect(MovePlanner.setTemperature(.bed, celsius: -5, profile: profile).plan == nil)
    }

    @Test("The PLA preset heats to the temperature this printer's filament wants")
    func plaPreset() throws {
        let pla = try #require(PreheatPreset.standard(for: profile).first { $0.id == "pla" })
        #expect(pla.hotend == 210)
        #expect(pla.bed == 60)
    }

    // MARK: Pausing and resuming

    @Test("Parking restores all four combinations of movement and extrusion modes")
    func pauseParkRestoresModalFlags() throws {
        let position = PositionReport(x: 100, y: 100, z: 20)

        for relativeMoves in [false, true] {
            for relativeExtrusion in [false, true] {
                var modal = GCodeModalState()
                modal.relativeMoves = relativeMoves
                modal.relativeExtrusion = relativeExtrusion

                let plan = try #require(
                    MovePlanner.pausePark(from: position, modal: modal, profile: profile).plan
                )

                #expect(plan.commands.suffix(2) == [
                    relativeMoves ? "G91" : "G90",
                    relativeExtrusion ? "M83" : "M82",
                ])
            }
        }
    }

    @Test("Parking clamps the lift at the top of the build volume")
    func pauseParkClampsZLift() throws {
        let position = PositionReport(x: 100, y: 100, z: 297)
        let plan = try #require(
            MovePlanner.pausePark(from: position, modal: GCodeModalState(), profile: profile).plan
        )

        #expect(plan.commands.contains("G0 Z3 F600"))
        #expect(plan.commands.contains("G0 Z10 F600") == false)
    }

    @Test("Parking clamps an out-of-range park point to the build volume")
    func pauseParkClampsXY() throws {
        var constrainedProfile = profile
        constrainedProfile.parkX = -20
        constrainedProfile.parkY = 500

        let plan = try #require(MovePlanner.pausePark(
            from: PositionReport(x: 100, y: 100, z: 20),
            modal: GCodeModalState(),
            profile: constrainedProfile
        ).plan)

        #expect(plan.commands.contains("G0 X0 Y220 F3000"))
    }

    @Test("Parking is refused when the current position is unknown")
    func pauseParkNeedsPosition() {
        let result = MovePlanner.pausePark(from: nil, modal: GCodeModalState(), profile: profile)
        #expect(result.plan == nil)
        #expect(result.refusal?.contains("cannot promise to put it back") == true)
    }

    @Test("Resuming restores the file's feedrate last")
    func resumeReturnRestoresFeedrateLast() throws {
        var modal = GCodeModalState()
        modal.feedrate = 1234.5

        let plan = try #require(MovePlanner.resumeReturn(
            to: PositionReport(x: 40, y: 50, z: 12),
            modal: modal,
            profile: profile
        ).plan)

        #expect(plan.commands.last == "G1 F1234.5")
    }

    // MARK: Formatting

    @Test("Numbers reach Marlin without trailing zeros or a negative zero")
    func numberFormatting() {
        #expect(MovePlanner.format(10) == "10")
        #expect(MovePlanner.format(0.1) == "0.1")
        #expect(MovePlanner.format(-2.5) == "-2.5")
        #expect(MovePlanner.format(3.14159) == "3.142")
        #expect(MovePlanner.format(-0.0) == "0")
    }
}

@Suite("Blocked reasons")
struct BlockedReasonTests {

    @Test("Movement is blocked until every axis is homed, and names the ones left")
    func movementNeedsHoming() throws {
        var state = PrinterState()
        state.activity = .connected

        let reason = try #require(state.movementBlockedReason())
        #expect(reason.contains("X, Y, Z"))

        state.homedAxes = [.x, .y]
        #expect(try #require(state.movementBlockedReason()).contains("Z"))

        state.homedAxes = [.x, .y, .z]
        #expect(state.movementBlockedReason() == nil)
    }

    @Test("Movement is blocked while a job is running")
    func movementBlockedDuringJob() {
        var state = PrinterState()
        state.activity = .printing
        state.homedAxes = Set(PrinterAxis.allCases)
        #expect(state.movementBlockedReason() != nil)
    }

    @Test("Extrusion is blocked below the cold-extrusion threshold, with the reason why")
    func coldExtrusion() throws {
        let profile = PrinterProfile.ender5Pro
        var state = PrinterState()
        state.activity = .connected
        state.hotend = HeaterTemperature(current: 25, target: 210)

        let reason = try #require(state.extrusionBlockedReason(profile: profile))
        #expect(reason.contains("170"))
        #expect(reason.contains("25"))

        state.hotend = HeaterTemperature(current: 205, target: 210)
        #expect(state.extrusionBlockedReason(profile: profile) == nil)
    }

    @Test("Extrusion waits for a real temperature reading rather than assuming cold")
    func noReadingYet() throws {
        var state = PrinterState()
        state.activity = .connected
        #expect(try #require(state.extrusionBlockedReason(profile: .ender5Pro)).contains("Waiting"))
    }
}

@Suite("Printer profile storage")
struct PrinterProfileStoreTests {

    @Test("A profile saved by an older version still loads")
    func toleratesMissingKeys() throws {
        // Exactly what Milestone 1 wrote: no jog feedrates, no extrude feedrate.
        let legacy = """
        {
          "baudRate": 115200,
          "filamentDiameter": 1.75,
          "maxBedTemperature": 110,
          "maxHotendTemperature": 260,
          "maxInFlightCommands": 1,
          "maxX": 235,
          "maxY": 235,
          "maxZ": 300,
          "minX": 0,
          "minY": 0,
          "minZ": 0,
          "minimumExtrusionTemperature": 170,
          "name": "Ender-5 Pro",
          "nozzleDiameter": 0.4,
          "plaBedTemperature": 60,
          "plaNozzleTemperature": 200,
          "preferredPortPath": "/dev/cu.usbserial-1110",
          "temperaturePollInterval": 2,
          "useLineNumbersAndChecksums": true
        }
        """

        let profile = try JSONDecoder().decode(PrinterProfile.self, from: Data(legacy.utf8))

        // The settings the user had chosen must survive…
        #expect(profile.preferredPortPath == "/dev/cu.usbserial-1110")
        #expect(profile.maxX == 235)
        #expect(profile.plaNozzleTemperature == 200)
        // …and the new fields fill in from the defaults.
        #expect(profile.jogFeedrateXY == 3000)
        #expect(profile.jogFeedrateZ == 600)
        #expect(profile.extrudeFeedrate == 300)
    }

    @Test("A profile survives a round trip through JSON")
    func roundTrip() throws {
        var profile = PrinterProfile.ender5Pro
        profile.preferredPortPath = "/dev/cu.usbserial-1110"
        profile.jogFeedrateXY = 1800

        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(PrinterProfile.self, from: data) == profile)
    }
}
