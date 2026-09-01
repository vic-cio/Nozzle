import Testing
import Foundation
@testable import NozzleCore

/// A read-only smoke test against a physically attached printer.
///
/// Skipped unless `NOZZLE_REAL_PORT` is set, so `swift test` stays hardware-free:
///
///     NOZZLE_REAL_PORT=/dev/cu.usbserial-1110 swift test --filter Hardware
///
/// Sends only queries — `M115`, `M105`, `M114`. No movement, no heaters.
@Suite("Hardware", .serialized)
struct HardwareSmokeTests {

    @Test("Handshake against a real printer")
    func handshake() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOZZLE_REAL_PORT"] else {
            print("[skipped: set NOZZLE_REAL_PORT to run]")
            return
        }
        let baud = Int(ProcessInfo.processInfo.environment["NOZZLE_BAUD"] ?? "115200") ?? 115_200

        let transport = PosixSerialTransport(path: path, baudRate: baud)
        var configuration = MarlinConfiguration()
        configuration.startBannerTimeout = 6
        let connection = MarlinConnection(transport: transport, configuration: configuration)

        let recorder = EventRecorder()
        await recorder.start(connection)

        try await connection.connect()
        #expect(await connection.state == .ready)

        let firmware = try #require(await connection.firmware, "printer did not answer M115")
        print("--- FIRMWARE: \(firmware.firmwareName ?? "?") / \(firmware.machineType ?? "?")")
        print("--- EMERGENCY_PARSER: \(firmware.supports(.emergencyParser))")
        print("--- AUTOREPORT_TEMP:  \(firmware.supports(.autoreportTemperature))")

        try await connection.send("M114", priority: .high, timeout: 10)

        // Whatever route it takes — auto-report or polling — readings must keep arriving.
        let gotTemperature = await waitUntil(timeout: 20) { await !recorder.temperatures.isEmpty }
        #expect(gotTemperature, "no temperature reading arrived")

        let before = await recorder.temperatures.count
        let keepsUpdating = await waitUntil(timeout: 20) { await recorder.temperatures.count > before }
        #expect(keepsUpdating, "temperature readings stopped arriving after the first one")

        print("--- AUTOREPORT IN USE: \(await connection.isTemperatureAutoreporting)")
        print("--- TEMPERATURE UPDATES: \(await recorder.temperatures.count)")
        for line in await recorder.warnings { print("--- WARNING: \(line)") }

        await connection.disconnect()
        await recorder.stop()
    }
}
