import Testing
import Foundation
@testable import NozzleCore

/// Milestone 2's commands driven through the real protocol layer into the simulated
/// firmware, so the assertions are about where the machine ended up — not only about
/// which strings were generated.
private func makeConnection(
    _ behaviour: MockPrinterBehaviour = MockPrinterBehaviour()
) -> (MarlinConnection, MockMarlinPrinter) {
    let printer = MockMarlinPrinter(behaviour: behaviour)
    var configuration = MarlinConfiguration()
    configuration.startBannerTimeout = 1
    configuration.temperaturePollInterval = 0.2
    return (MarlinConnection(transport: printer, configuration: configuration), printer)
}

private func run(_ plan: MovePlan, on connection: MarlinConnection) async throws {
    for command in plan.commands {
        try await connection.send(command, priority: .high)
    }
}

@Suite("Movement against the simulated printer", .serialized)
struct MovementIntegrationTests {

    @Test("Homing moves the axes to their endstops and marks them homed")
    func homing() async throws {
        let (connection, printer) = makeConnection()
        try await connection.connect()

        try await run(MovePlanner.home([]), on: connection)

        let snapshot = printer.snapshot
        #expect(snapshot.homedAxes == Set(PrinterAxis.allCases))
        #expect(snapshot.position.x == 0)
        #expect(snapshot.position.y == 0)
        #expect(snapshot.position.z == 0)

        await connection.disconnect()
    }

    @Test("Homing one axis leaves the others alone")
    func homingOneAxis() async throws {
        let (connection, printer) = makeConnection()
        try await connection.connect()

        try await run(MovePlanner.home([.z]), on: connection)

        #expect(printer.snapshot.homedAxes == [.z])

        await connection.disconnect()
    }

    @Test("A jog moves by the requested distance, not to it")
    func jogIsRelativeOnTheMachine() async throws {
        // The bug this guards against: sending `G0 X10` in absolute mode when a 10 mm
        // nudge was meant. From X100 that is a 90 mm move in the wrong direction.
        let (connection, printer) = makeConnection()
        try await connection.connect()

        try await run(MovePlanner.home([]), on: connection)
        try await run(MovePlan(commands: ["G90", "G0 X100 Y50"]), on: connection)

        let plan = try #require(MovePlanner.jog(
            axis: .x, millimetres: 10, from: PositionReport(x: 100, y: 50, z: 0), profile: .ender5Pro
        ).plan)
        try await run(plan, on: connection)

        let snapshot = printer.snapshot
        #expect(snapshot.position.x == 110)
        #expect(snapshot.position.y == 50)
        // And the printer must be left in absolute mode, ready for a print.
        #expect(snapshot.relativeMoves == false)

        await connection.disconnect()
    }

    @Test("The position reported afterwards is the position we jogged to")
    func positionReportFollowsTheJog() async throws {
        let (connection, printer) = makeConnection()
        let recorder = EventRecorder()
        await recorder.start(connection)
        try await connection.connect()

        try await run(MovePlanner.home([]), on: connection)
        let plan = try #require(MovePlanner.jog(
            axis: .y, millimetres: 25, from: PositionReport(x: 0, y: 0, z: 0), profile: .ender5Pro
        ).plan)
        try await run(plan, on: connection)
        try await run(MovePlan(commands: ["M400", "M114"]), on: connection)

        let positions = await recorder.events.compactMap {
            if case .position(let report) = $0 { return report } else { return nil }
        }
        #expect(positions.last?.y == 25)
        #expect(printer.snapshot.position.y == 25)

        await connection.disconnect()
        await recorder.stop()
    }

    @Test("A levelling shortcut reaches the corner without changing Z")
    func bedLevelCornerPreservesZ() async throws {
        let (connection, printer) = makeConnection()
        try await connection.connect()

        try await run(MovePlanner.home([]), on: connection)
        try await run(MovePlan(commands: ["G90", "G0 X0 Y110 Z7"]), on: connection)
        let plan = try #require(MovePlanner.moveToBedLevelCorner(
            .rearRight, from: printer.snapshot.position, profile: .ender5Pro
        ).plan)
        try await run(plan, on: connection)

        #expect(printer.snapshot.position.x == 190)
        #expect(printer.snapshot.position.y == 190)
        #expect(printer.snapshot.position.z == 7)

        await connection.disconnect()
    }

    @Test("Turning the motors off makes the printer forget it was homed")
    func motorsOff() async throws {
        let (connection, printer) = makeConnection()
        try await connection.connect()

        try await run(MovePlanner.home([]), on: connection)
        #expect(printer.snapshot.homedAxes.isEmpty == false)

        try await run(MovePlanner.disableMotors(), on: connection)
        #expect(printer.snapshot.homedAxes.isEmpty)

        await connection.disconnect()
    }

    @Test("Extruding pushes filament and leaves E in absolute mode")
    func extrusion() async throws {
        let (connection, printer) = makeConnection()
        try await connection.connect()

        try await run(try #require(MovePlanner.extrude(millimetres: 5, profile: .ender5Pro).plan), on: connection)
        try await run(try #require(MovePlanner.extrude(millimetres: 5, profile: .ender5Pro).plan), on: connection)

        let snapshot = printer.snapshot
        // Two 5 mm extrusions must add up. If M83 were missing, the second would be a
        // move *to* E5 and the filament would not budge.
        #expect(snapshot.position.e == 10)
        #expect(snapshot.relativeExtrusion == false)

        await connection.disconnect()
    }

    @Test("Retracting pulls filament back")
    func retraction() async throws {
        let (connection, printer) = makeConnection()
        try await connection.connect()

        try await run(try #require(MovePlanner.extrude(millimetres: 10, profile: .ender5Pro).plan), on: connection)
        try await run(try #require(MovePlanner.extrude(millimetres: -4, profile: .ender5Pro).plan), on: connection)

        #expect(printer.snapshot.position.e == 6)

        await connection.disconnect()
    }

    @Test("Setting heater targets reaches the printer and comes back in the readings")
    func heaterTargets() async throws {
        let (connection, printer) = makeConnection()
        let recorder = EventRecorder()
        await recorder.start(connection)
        try await connection.connect()

        try await run(try #require(MovePlanner.setTemperature(.hotend, celsius: 210, profile: .ender5Pro).plan), on: connection)
        try await run(try #require(MovePlanner.setTemperature(.bed, celsius: 60, profile: .ender5Pro).plan), on: connection)
        try await connection.send("M105", priority: .high)

        let snapshot = printer.snapshot
        #expect(snapshot.hotendTarget == 210)
        #expect(snapshot.bedTarget == 60)

        let sawTargets = await waitUntil {
            await recorder.temperatures.contains { $0.hotend?.target == 210 && $0.bed?.target == 60 }
        }
        #expect(sawTargets, "the new targets should appear in a temperature report")

        await connection.disconnect()
        await recorder.stop()
    }

    @Test("Turning the heaters off sets both targets to zero")
    func heatersOff() async throws {
        let (connection, printer) = makeConnection()
        try await connection.connect()

        try await run(try #require(MovePlanner.setTemperature(.hotend, celsius: 200, profile: .ender5Pro).plan), on: connection)
        try await run(MovePlanner.heatersOff(), on: connection)

        #expect(printer.snapshot.hotendTarget == 0)
        #expect(printer.snapshot.bedTarget == 0)

        await connection.disconnect()
    }

    @Test("A jog survives a resend without moving twice")
    func jogSurvivesResend() async throws {
        // A replayed line must be the *same* relative move, not an extra one on top.
        var behaviour = MockPrinterBehaviour()
        behaviour.corruptLineOnce = 7
        let (connection, printer) = makeConnection(behaviour)
        try await connection.connect()

        try await run(MovePlanner.home([]), on: connection)
        for _ in 0..<4 {
            let plan = try #require(MovePlanner.jog(
                axis: .x, millimetres: 10, from: printer.snapshot.position, profile: .ender5Pro
            ).plan)
            try await run(plan, on: connection)
        }

        // Four 10 mm nudges from home, whatever the wire did in between.
        #expect(printer.snapshot.position.x == 40)
        #expect(await connection.state == .ready)

        await connection.disconnect()
    }

    @Test("An unexpected reset is announced so the host can drop its homed state")
    func resetIsAnnounced() async throws {
        let (connection, printer) = makeConnection()
        let recorder = EventRecorder()
        await recorder.start(connection)
        try await connection.connect()

        printer.injectLine("start")

        let announced = await waitUntil {
            await recorder.events.contains { if case .printerReset = $0 { return true } else { return false } }
        }
        #expect(announced, "a mid-session reset must be reported, not only logged")

        await connection.disconnect()
        await recorder.stop()
    }
}
