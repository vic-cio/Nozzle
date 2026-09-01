import Testing
import Foundation
@testable import NozzleCore

private let smallPrint = """
;FLAVOR:Marlin
;TIME:200
;MINX:10
;MINY:10
;MINZ:0.2
;MAXX:110
;MAXY:110
;MAXZ:5
M140 S50
M104 S210
G28
G92 E0
;LAYER_COUNT:2
;LAYER:0
G1 X10 Y10 Z0.2 F1500 E1
G1 X100 Y10 E2
G1 X100 Y100 E3
;TIME_ELAPSED:100.0
;LAYER:1
G1 Z0.4
G1 X10 Y100 E4
G1 X10 Y10 E5
;TIME_ELAPSED:200.0
M104 S0
M140 S0
M84
;End of Gcode
"""

private func makeJob(
    _ behaviour: MockPrinterBehaviour = MockPrinterBehaviour(),
    profile: PrinterProfile = .ender5Pro
) throws -> (PrintJob, MarlinConnection, MockMarlinPrinter, GCodeFile) {
    let printer = MockMarlinPrinter(behaviour: behaviour)
    var configuration = MarlinConfiguration()
    configuration.startBannerTimeout = 1
    configuration.temperaturePollInterval = 0.2
    let connection = MarlinConnection(transport: printer, configuration: configuration)
    let file = try GCodeFile.parse(smallPrint, name: "small.gcode")
    return (PrintJob(file: file, connection: connection, profile: profile), connection, printer, file)
}

/// Collects what the UI would have seen from a running print.
private actor JobRecorder {
    private(set) var progress: [PrintProgress] = []
    private(set) var phases: [PrintJobPhase] = []
    private(set) var layers: [Int] = []
    private var task: Task<Void, Never>?

    func start(_ job: PrintJob) {
        let stream = job.events
        task = Task { [weak self] in
            for await event in stream { await self?.record(event) }
        }
    }

    private func record(_ event: PrintJobEvent) {
        switch event {
        case .progress(let value): progress.append(value)
        case .phase(let value):    phases.append(value)
        case .layer(let value):    layers.append(value)
        case .note(let value):     notes.append(value)
        }
    }

    private(set) var notes: [String] = []

    func stop() { task?.cancel() }
}

@Suite("Printing a file", .serialized)
struct PrintJobTests {

    @Test("Every command in the file reaches the printer, in order and only once")
    func streamsWholeFile() async throws {
        let (job, connection, _, file) = try makeJob()
        let traffic = EventRecorder()
        await traffic.start(connection)
        try await connection.connect()

        await job.run()

        #expect(await job.currentPhase == .finished)
        #expect(await job.currentProgress.commandsSent == file.commandCount)

        // The moves must appear on the wire in file order, each exactly once.
        let sent = await traffic.transmitted
        let moves = sent.compactMap { line -> String? in
            guard let range = line.range(of: "G1 ") else { return nil }
            return String(line[range.lowerBound...].prefix(while: { $0 != "*" }))
        }
        #expect(moves == [
            "G1 X10 Y10 Z0.2 F1500 E1",
            "G1 X100 Y10 E2",
            "G1 X100 Y100 E3",
            "G1 Z0.4",
            "G1 X10 Y100 E4",
            "G1 X10 Y10 E5",
        ])

        await connection.disconnect()
        await traffic.stop()
    }

    @Test("Comment-only lines are never sent")
    func skipsComments() async throws {
        let (job, connection, _, _) = try makeJob()
        let traffic = EventRecorder()
        await traffic.start(connection)
        try await connection.connect()

        await job.run()

        #expect(await traffic.transmitted.contains { $0.contains("LAYER") } == false)
        #expect(await traffic.transmitted.contains { $0.contains("End of Gcode") } == false)

        await connection.disconnect()
        await traffic.stop()
    }

    @Test("The print ends with the machine where the file left it")
    func reachesTheEnd() async throws {
        let (job, connection, printer, _) = try makeJob()
        try await connection.connect()

        await job.run()

        let snapshot = printer.snapshot
        #expect(snapshot.position.x == 10)
        #expect(snapshot.position.y == 10)
        // The file's own footer turns the heaters off; nothing here should leave them on.
        #expect(snapshot.hotendTarget == 0)
        #expect(snapshot.bedTarget == 0)

        await connection.disconnect()
    }

    @Test("Progress is reported, ends at the end, and counts layers")
    func reportsProgress() async throws {
        let (job, connection, _, _) = try makeJob()
        let recorder = JobRecorder()
        await recorder.start(job)
        try await connection.connect()

        await job.run()
        // Let the final events drain out of the stream.
        _ = await waitUntil { await recorder.phases.contains(.finished) }

        let progress = await recorder.progress
        #expect(!progress.isEmpty)
        let last = try #require(progress.last)
        #expect(last.fraction == 1)
        #expect(last.layerCount == 2)
        #expect(await recorder.layers == [0, 1])

        await connection.disconnect()
        await recorder.stop()
    }

    @Test("Remaining time comes from the slicer's layer timings, not from lines sent")
    func remainingTimeIsTimeBased() async throws {
        let (job, connection, _, file) = try makeJob()
        try await connection.connect()

        await job.run()

        // Where layer 0 closes, the slicer's own figure is exactly 100 s of 200 s — even
        // though that point is nowhere near half the commands in the file.
        let closeOfFirstLayer = file.layers[0].endLineIndex
        #expect(file.estimatedElapsed(atLineIndex: closeOfFirstLayer) == 100)
        #expect(file.estimatedRemaining(atLineIndex: closeOfFirstLayer) == 100)

        // Sanity: that is genuinely not the halfway point by command count.
        let commandsByThen = file.commandLineIndices.filter { $0 <= closeOfFirstLayer }.count
        #expect(Double(commandsByThen) / Double(file.commandCount) != 0.5)

        await connection.disconnect()
    }

    @Test("Stopping halts the stream and leaves the machine safe")
    func stopping() async throws {
        var behaviour = MockPrinterBehaviour()
        behaviour.responseDelay = 0.02          // slow enough to interrupt mid-file
        let (job, connection, printer, file) = try makeJob(behaviour)
        try await connection.connect()

        let running = Task { await job.run() }
        _ = await waitUntil { await job.currentProgress.commandsSent >= 2 }
        await job.stop()
        await running.value

        #expect(await job.currentPhase == .cancelled)
        #expect(await job.currentProgress.commandsSent < file.commandCount)

        // The point of stopping: no heat left on, and the nozzle lifted off the part.
        let snapshot = printer.snapshot
        #expect(snapshot.hotendTarget == 0)
        #expect(snapshot.bedTarget == 0)
        #expect(snapshot.homedAxes.isEmpty)     // M84 released the steppers
        #expect(snapshot.relativeMoves == false, "the Z lift must not leave relative mode on")

        await connection.disconnect()
    }

    @Test("Pausing parks, restores modal state, and resumes without changing extrusion")
    func pauseAndResume() async throws {
        var behaviour = MockPrinterBehaviour()
        behaviour.responseDelay = 0.02
        let (job, connection, printer, _) = try makeJob(behaviour)
        try await connection.connect()

        let running = Task { await job.run() }
        _ = await waitUntil { await job.currentProgress.commandsSent >= 5 }
        await job.pause()

        let parked = await waitUntil { await job.currentPhase == .paused }
        #expect(parked)

        let snapshot = printer.snapshot
        #expect(snapshot.position.x == 10)
        #expect(snapshot.position.y == 10)
        #expect(snapshot.position.z == 10.2)
        #expect(snapshot.relativeMoves == false)
        #expect(snapshot.relativeExtrusion == false)

        await job.resume()
        await running.value

        #expect(await job.currentPhase == .finished)
        #expect(printer.snapshot.position.e == 5)

        await connection.disconnect()
    }

    @Test("Stopping while paused does not lift twice and still cancels")
    func stopWhilePaused() async throws {
        var behaviour = MockPrinterBehaviour()
        behaviour.responseDelay = 0.02
        let (job, connection, printer, _) = try makeJob(behaviour)
        try await connection.connect()

        let running = Task { await job.run() }
        _ = await waitUntil { await job.currentProgress.commandsSent >= 5 }
        await job.pause()
        let parked = await waitUntil { await job.currentPhase == .paused }
        #expect(parked)
        let parkedZ = printer.snapshot.position.z

        await job.stop()
        await running.value

        #expect(await job.currentPhase == .cancelled)
        #expect(printer.snapshot.position.z == parkedZ)
        #expect(printer.snapshot.hotendTarget == 0)
        #expect(printer.snapshot.bedTarget == 0)
        #expect(printer.snapshot.homedAxes.isEmpty)

        await connection.disconnect()
    }

    @Test("Losing the printer mid-print fails the job instead of pretending to continue")
    func disconnectMidPrint() async throws {
        var behaviour = MockPrinterBehaviour()
        // The handshake spends a few commands; drop the link shortly into the file.
        behaviour.disconnectAfterCommands = 8
        let (job, connection, _, file) = try makeJob(behaviour)
        let recorder = JobRecorder()
        await recorder.start(job)
        try await connection.connect()

        await job.run()

        let phase = await job.currentPhase
        guard case .failed = phase else {
            Issue.record("expected the job to fail, but it was \(phase)")
            return
        }
        #expect(await job.currentProgress.commandsSent < file.commandCount)

        await recorder.stop()
    }

    @Test("A resend mid-print is recovered from without losing or repeating a command")
    func survivesResend() async throws {
        var behaviour = MockPrinterBehaviour()
        behaviour.corruptLineOnce = 9
        let (job, connection, printer, _) = try makeJob(behaviour)
        try await connection.connect()

        await job.run()

        #expect(await job.currentPhase == .finished)
        // E advances once per move; a duplicated line would overshoot it.
        #expect(printer.snapshot.position.e == 5)

        await connection.disconnect()
    }
}
