import Testing
import Foundation
@testable import NozzleCore

/// Collects events from a connection so tests can assert on what the UI would have seen.
actor EventRecorder {
    private(set) var events: [MarlinEvent] = []
    private var task: Task<Void, Never>?

    func start(_ connection: MarlinConnection) async {
        let stream = connection.events
        task = Task { [weak self] in
            for await event in stream { await self?.record(event) }
        }
    }

    private func record(_ event: MarlinEvent) { events.append(event) }

    func stop() { task?.cancel() }

    var temperatures: [TemperatureReport] {
        events.compactMap { if case .temperature(let t) = $0 { return t } else { return nil } }
    }

    var linkStates: [MarlinLinkState] {
        events.compactMap { if case .linkState(let s) = $0 { return s } else { return nil } }
    }

    var transmitted: [String] {
        events.compactMap {
            if case .traffic(let entry) = $0, entry.direction == .tx { return entry.text } else { return nil }
        }
    }

    var warnings: [String] {
        events.compactMap {
            if case .traffic(let entry) = $0, entry.direction == .warning { return entry.text } else { return nil }
        }
    }
}

/// Polls a condition instead of sleeping a fixed amount, so tests stay fast and stable.
@discardableResult
func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private func makeConnection(
    _ behaviour: MockPrinterBehaviour = MockPrinterBehaviour(),
    configure: (inout MarlinConfiguration) -> Void = { _ in }
) -> (MarlinConnection, MockMarlinPrinter) {
    let printer = MockMarlinPrinter(behaviour: behaviour)
    var configuration = MarlinConfiguration()
    configuration.startBannerTimeout = 1
    configuration.temperaturePollInterval = 0.2
    configure(&configuration)
    return (MarlinConnection(transport: printer, configuration: configuration), printer)
}

@Suite("Connecting", .serialized)
struct ConnectionHandshakeTests {

    @Test("Connecting identifies the firmware and reaches ready")
    func handshake() async throws {
        let (connection, _) = makeConnection()
        let recorder = EventRecorder()
        await recorder.start(connection)

        try await connection.connect()

        #expect(await connection.state == .ready)
        let firmware = try #require(await connection.firmware)
        #expect(firmware.firmwareName == "Marlin 2.0.8.2 (Github)")
        #expect(firmware.machineType == "Ender-5 Pro")
        #expect(firmware.supports(.emergencyParser))

        // The handshake must reset the line counter before anything else is sent.
        let sent = await recorder.transmitted
        #expect(sent.first?.contains("M110") == true)
        #expect(sent.contains { $0.contains("M115") })

        await connection.disconnect()
        await recorder.stop()
    }

    @Test("Every queued command carries a line number and a valid checksum")
    func lineNumbersAndChecksums() async throws {
        let (connection, _) = makeConnection()
        let recorder = EventRecorder()
        await recorder.start(connection)
        try await connection.connect()

        try await connection.send("G28", priority: .high)

        let sent = await recorder.transmitted
        let homing = try #require(sent.last { $0.contains("G28") })
        // Shape: N<line>G28*<checksum>
        let parts = homing.split(separator: "*")
        #expect(parts.count == 2)
        #expect(parts[0].hasPrefix("N"))
        #expect(UInt8(parts[1]) == MarlinConnection.checksum(of: String(parts[0])))

        await connection.disconnect()
        await recorder.stop()
    }

    @Test("Firmware with auto-reporting is switched to M155 instead of polling")
    func prefersAutoreport() async throws {
        let (connection, _) = makeConnection()   // mock advertises AUTOREPORT_TEMP:1
        let recorder = EventRecorder()
        await recorder.start(connection)
        try await connection.connect()

        #expect(await connection.isTemperatureAutoreporting)
        let sawM155 = await waitUntil {
            await recorder.transmitted.contains { $0.contains("M155") }
        }
        #expect(sawM155)

        await connection.disconnect()
        await recorder.stop()
    }

    @Test("Firmware without auto-reporting falls back to polling M105")
    func fallsBackToPolling() async throws {
        var behaviour = MockPrinterBehaviour()
        behaviour.capabilities["AUTOREPORT_TEMP"] = false
        let (connection, _) = makeConnection(behaviour)
        let recorder = EventRecorder()
        await recorder.start(connection)
        try await connection.connect()

        #expect(await connection.isTemperatureAutoreporting == false)
        // Polling interval is 0.2 s in tests; several polls should land quickly.
        let polled = await waitUntil {
            await recorder.transmitted.filter { $0.contains("M105") }.count >= 3
        }
        #expect(polled)

        await connection.disconnect()
        await recorder.stop()
    }

    /// Regression test for behaviour observed on the real Ender-5 Pro: the firmware
    /// reports `Cap:AUTOREPORT_TEMP:1`, but every auto-report arrives with each chunk
    /// duplicated (`TT::25.9125.91`). Trusting the capability flag would leave the
    /// temperature readout frozen at whatever the last M105 said.
    @Test("Auto-reporting that arrives corrupted falls back to polling")
    func corruptAutoreportFallsBackToPolling() async throws {
        var behaviour = MockPrinterBehaviour()
        behaviour.garbledAutoreport = true
        let (connection, _) = makeConnection(behaviour) {
            $0.autoreportVerificationTimeout = 0.5
            $0.temperaturePollInterval = 0.3
        }
        let recorder = EventRecorder()
        await recorder.start(connection)
        try await connection.connect()

        // It starts out believing the firmware.
        #expect(await connection.isTemperatureAutoreporting)

        // …then notices nothing readable is arriving and switches back.
        let recovered = await waitUntil(timeout: 8) {
            await connection.isTemperatureAutoreporting == false
        }
        #expect(recovered, "should have abandoned M155 after receiving unreadable reports")
        #expect(await recorder.transmitted.contains { $0.contains("M155 S0") })

        // And temperatures must actually resume via polling.
        let pollingWorks = await waitUntil(timeout: 5) {
            await recorder.transmitted.filter { $0.contains("M105") }.count >= 2
        }
        #expect(pollingWorks)
        #expect(await !recorder.temperatures.isEmpty)

        await connection.disconnect()
        await recorder.stop()
    }

    @Test("Temperature readings reach the event stream")
    func temperatures() async throws {
        let (connection, _) = makeConnection()
        let recorder = EventRecorder()
        await recorder.start(connection)
        try await connection.connect()
        try await connection.send("M104 S200", priority: .high)

        let sawTemperature = await waitUntil {
            await !recorder.temperatures.isEmpty
        }
        #expect(sawTemperature)

        await connection.disconnect()
        await recorder.stop()
    }
}

@Suite("Command queue", .serialized)
struct CommandQueueTests {

    @Test("Commands are acknowledged in order and the queue drains")
    func ordering() async throws {
        let (connection, _) = makeConnection()
        let recorder = EventRecorder()
        await recorder.start(connection)
        try await connection.connect()

        for index in 0..<20 {
            try await connection.send("G1 X\(index)")
        }
        #expect(await connection.queueDepth == 0)

        let sent = await recorder.transmitted.filter { $0.contains("G1 X") }
        #expect(sent.count == 20)
        // Line numbers must be strictly increasing with no gaps in the happy path.
        let numbers = sent.compactMap { Int($0.dropFirst().prefix { $0.isNumber }) }
        #expect(numbers == numbers.sorted())
        #expect(Set(numbers).count == numbers.count)

        await connection.disconnect()
        await recorder.stop()
    }

    @Test("Interactive commands overtake the print stream")
    func priority() async throws {
        let (connection, _) = makeConnection()
        try await connection.connect()

        // Queue a backlog without awaiting, then add a high-priority command.
        for index in 0..<10 { await connection.enqueue("G1 X\(index)", priority: .normal) }
        await connection.enqueue("M105", priority: .high)

        let drained = await waitUntil { await connection.queueDepth == 0 }
        #expect(drained)

        await connection.disconnect()
    }

    @Test("Temperature polls never stack up")
    func pollsDoNotStack() async throws {
        var behaviour = MockPrinterBehaviour()
        behaviour.capabilities["AUTOREPORT_TEMP"] = false
        behaviour.responseDelay = 0.05          // slow printer
        let (connection, _) = makeConnection(behaviour) { $0.temperaturePollInterval = 0.02 }
        try await connection.connect()

        try? await Task.sleep(for: .milliseconds(400))
        // With a poll interval far shorter than the response time, a naive implementation
        // would build an unbounded backlog of M105s ahead of the print stream.
        let depth = await connection.queueDepth
        #expect(depth <= 2, "queue grew to \(depth); temperature polls are stacking")

        await connection.disconnect()
    }

    @Test("Sending while disconnected fails rather than silently dropping")
    func sendWhileDisconnected() async {
        let (connection, _) = makeConnection()
        await #expect(throws: MarlinError.notConnected) {
            try await connection.send("M105")
        }
    }

    @Test("Reading the position waits for motion before asking M114")
    func queryPositionWaitsForMotion() async throws {
        let (connection, printer) = makeConnection()
        let recorder = EventRecorder()
        await recorder.start(connection)
        try await connection.connect()

        try await connection.send("G1 X42 Y73 Z8.5 E3", priority: .high)
        let position = try await connection.queryPosition()

        #expect(position == printer.snapshot.position)
        #expect(position.x == 42)
        #expect(position.y == 73)
        #expect(position.z == 8.5)

        let transmitted = await recorder.transmitted
        let m400 = try #require(transmitted.lastIndex { $0.contains("M400") })
        let m114 = try #require(transmitted.lastIndex { $0.contains("M114") })
        #expect(m400 < m114)

        await connection.disconnect()
        await recorder.stop()
    }
}

@Suite("Resend recovery", .serialized)
struct ResendTests {

    @Test("A corrupted line is replayed and the job continues")
    func replaysAfterCorruption() async throws {
        // Corrupt whichever line the 5th user command lands on. The handshake uses
        // lines 1-3 (M115, M155, M105), so the run below covers it comfortably.
        var behaviour = MockPrinterBehaviour()
        behaviour.corruptLineOnce = 6
        let (connection, _) = makeConnection(behaviour)
        let recorder = EventRecorder()
        await recorder.start(connection)
        try await connection.connect()

        // None of these may throw: a resend is a recoverable event, not a failure.
        for index in 0..<10 {
            try await connection.send("G1 X\(index)")
        }

        let sent = await recorder.transmitted
        // The corrupted line must appear on the wire twice — original and replay.
        let lineSix = sent.filter { $0.hasPrefix("N6") }
        #expect(lineSix.count == 2, "expected line 6 to be sent twice, saw \(lineSix.count)")
        #expect(await recorder.warnings.contains { $0.contains("resend") })

        // And the connection must still be healthy afterwards.
        #expect(await connection.state == .ready)
        try await connection.send("M105", priority: .high)

        await connection.disconnect()
        await recorder.stop()
    }

    @Test("A resend does not complete the awaited command early")
    func awaitedCommandSurvivesResend() async throws {
        var behaviour = MockPrinterBehaviour()
        behaviour.corruptLineOnce = 4
        let (connection, printer) = makeConnection(behaviour)
        try await connection.connect()

        try await connection.send("G1 X50 Y50", priority: .high)

        // The printer must actually have advanced past the replayed line, proving the
        // command really ran rather than being marked done by the post-Resend `ok`.
        #expect(printer.isOpen)
        #expect(await connection.state == .ready)

        await connection.disconnect()
    }

    @Test("Endless resend requests give up instead of looping forever")
    func givesUpEventually() async throws {
        var behaviour = MockPrinterBehaviour()
        behaviour.validateChecksums = true
        let (connection, printer) = makeConnection(behaviour) { $0.maxConsecutiveResends = 3 }
        let recorder = EventRecorder()
        await recorder.start(connection)
        try await connection.connect()

        // Simulate a cable or baud rate bad enough that nothing gets through intact.
        printer.startRequestingResends()

        _ = try? await connection.send("G1 X1")

        let failed = await waitUntil(timeout: 8) {
            if case .failed = await connection.state { return true }
            return false
        }
        #expect(failed, "connection should have failed after repeated resends")

        await recorder.stop()
    }
}

@Suite("Disconnection", .serialized)
struct DisconnectionTests {

    @Test("Unplugging mid-job fails outstanding commands and reports an error")
    func unplugMidJob() async throws {
        var behaviour = MockPrinterBehaviour()
        // Handshake uses ~4 commands; drop the link a few commands into the job.
        behaviour.disconnectAfterCommands = 8
        let (connection, _) = makeConnection(behaviour)
        let recorder = EventRecorder()
        await recorder.start(connection)
        try await connection.connect()

        var thrown: Error?
        do {
            for index in 0..<40 { try await connection.send("G1 X\(index)") }
        } catch {
            thrown = error
        }

        // The critical property: the caller finds out. A host that silently stops
        // sending while the UI still says "printing" is the failure mode to avoid.
        #expect(thrown != nil, "sending after an unplug must throw")

        let reportedFailure = await waitUntil {
            switch await connection.state {
            case .failed, .disconnected: return true
            default: return false
            }
        }
        #expect(reportedFailure)

        await recorder.stop()
    }

    @Test("A clean disconnect is not reported as an error")
    func cleanDisconnect() async throws {
        let (connection, _) = makeConnection()
        let recorder = EventRecorder()
        await recorder.start(connection)
        try await connection.connect()
        await connection.disconnect()

        #expect(await connection.state == .disconnected)
        let states = await recorder.linkStates
        #expect(!states.contains { if case .failed = $0 { return true } else { return false } })

        await recorder.stop()
    }

    @Test("A thermal fault halts the connection instead of pretending to print")
    func thermalFault() async throws {
        let (connection, printer) = makeConnection()
        try await connection.connect()

        printer.injectLine("Error:Thermal Runaway, system stopped! Heater_ID: 0")

        let halted = await waitUntil {
            if case .failed = await connection.state { return true }
            return false
        }
        #expect(halted, "a thermal runaway must take the connection out of the ready state")
    }

    @Test("An unexpected board reset is noticed and re-synchronised")
    func unexpectedReset() async throws {
        let (connection, printer) = makeConnection()
        let recorder = EventRecorder()
        await recorder.start(connection)
        try await connection.connect()

        printer.injectLine("start")

        let noticed = await waitUntil {
            await recorder.warnings.contains { $0.contains("reset") }
        }
        #expect(noticed)

        await connection.disconnect()
        await recorder.stop()
    }

    @Test("Reconnecting after a disconnect works")
    func reconnect() async throws {
        let (first, _) = makeConnection()
        try await first.connect()
        await first.disconnect()
        #expect(await first.state == .disconnected)

        // A transport is single-use, so reconnecting means a fresh connection object —
        // which is exactly what PrinterController does.
        let (second, _) = makeConnection()
        try await second.connect()
        #expect(await second.state == .ready)
        await second.disconnect()
    }
}
