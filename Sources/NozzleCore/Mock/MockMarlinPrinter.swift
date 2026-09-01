import Foundation

/// How the simulated printer should behave, including the ways it should misbehave.
public struct MockPrinterBehaviour: Sendable {
    public var firmwareName = "Marlin 2.0.8.2 (Github)"
    public var machineType = "Ender-5 Pro"
    public var extruderCount = 1
    public var capabilities: [String: Bool] = [
        "EEPROM": true,
        "AUTOREPORT_TEMP": true,
        "EMERGENCY_PARSER": true,
        "HOST_ACTION_COMMANDS": true,
        "PROMPT_SUPPORT": true,
        "THERMAL_PROTECTION": true,
        "AUTOLEVEL": false,
        "SDCARD": true,
    ]

    /// Print the `start` banner on open, as a real board does after its DTR reset.
    public var emitStartBanner = true
    /// Artificial round-trip latency. Keep at 0 in tests for determinism.
    public var responseDelay: TimeInterval = 0
    /// Reject checksums and line numbers the way real firmware does.
    public var validateChecksums = true
    /// Append `N.. P.. B..` to every `ok`.
    public var advancedOk = false

    // MARK: Fault injection

    /// Corrupt the reception of this line number exactly once, forcing a resend.
    public var corruptLineOnce: Int?
    /// Drop the USB connection after this many commands have been received.
    public var disconnectAfterCommands: Int?
    /// Emit `echo:busy: processing` while handling long commands.
    public var emitBusyForLongCommands = true

    /// Reproduce a real Creality quirk: advertise `AUTOREPORT_TEMP`, then emit every
    /// chunk of the auto-report twice (`TT::25.9125.91`), which no parser can read.
    /// Observed on a stock "Marlin Creality 3D" Ender-5 Pro.
    public var garbledAutoreport = false

    // MARK: Physics

    public var ambientTemperature: Double = 22
    public var hotendHeatingRate: Double = 8.0   // °C per second
    public var bedHeatingRate: Double = 1.2
    public var coolingRate: Double = 0.6

    public init() {}
}

/// A simulated Marlin printer that speaks the real serial protocol.
///
/// Implements `SerialTransport`, so `MarlinConnection` cannot tell it apart from a
/// physical machine. This is what lets the whole print pipeline — queueing, checksums,
/// resend recovery, mid-job disconnects — be developed and tested with no hardware.
public final class MockMarlinPrinter: SerialTransport, @unchecked Sendable {

    public var displayPath: String { "Demo Printer" }
    public let events: AsyncStream<SerialEvent>
    private let eventSink: AsyncStream<SerialEvent>.Continuation

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.nozzle.mock-printer")
    private var behaviour: MockPrinterBehaviour

    private var opened = false
    private var assembler = LineAssembler()

    // Simulated machine state.
    private var expectedLineNumber = 1
    private var hotend: Double
    private var hotendTarget: Double = 0
    private var bed: Double
    private var bedTarget: Double = 0
    private var position = PositionReport(x: 0, y: 0, z: 0, e: 0)
    private var homedAxes: Set<PrinterAxis> = []
    /// `G90`/`G91`. Marlin boots in absolute mode.
    private var relativeMoves = false
    /// `M82`/`M83`. The extruder has its own flag, independent of `G90`/`G91`.
    private var relativeExtrusion = false
    private var commandsReceived = 0
    private var corruptionUsed = false
    private var alwaysRequestResend = false
    private var autoreportInterval: Int = 0
    private var physicsTimer: DispatchSourceTimer?
    private var autoreportTimer: DispatchSourceTimer?

    public init(behaviour: MockPrinterBehaviour = MockPrinterBehaviour()) {
        self.behaviour = behaviour
        self.hotend = behaviour.ambientTemperature
        self.bed = behaviour.ambientTemperature
        let (stream, continuation) = AsyncStream<SerialEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.eventSink = continuation
    }

    public var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return opened
    }

    // MARK: - Transport

    public func open() throws {
        lock.lock()
        guard !opened else { lock.unlock(); throw SerialError.alreadyOpen }
        opened = true
        let banner = behaviour.emitStartBanner
        lock.unlock()

        eventSink.yield(.opened)
        if banner {
            emit("start")
            emit("echo: Last Updated: 2020-09-01 | Author: (Creality)")
        }
        startPhysics()
    }

    public func write(_ bytes: [UInt8]) throws {
        guard isOpen else { throw SerialError.notOpen }
        let lines = { () -> [String] in
            lock.lock(); defer { lock.unlock() }
            return assembler.append(bytes)
        }()
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let delay = behaviour.responseDelay
            if delay > 0 {
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.process(line) }
            } else {
                queue.async { [weak self] in self?.process(line) }
            }
        }
    }

    public func close() {
        finish(error: nil)
    }

    /// Simulates the USB cable being pulled out.
    public func simulateUnplug() {
        finish(error: .deviceDisconnected)
    }

    /// Emits a raw line as though the firmware had sent it, for exercising host
    /// handling of events the mock does not otherwise produce (thermal faults,
    /// spontaneous resets).
    public func injectLine(_ line: String) {
        emit(line)
    }

    /// From now on, reject every command with a resend request. Used to prove the host
    /// gives up rather than looping forever against a printer it cannot talk to.
    public func startRequestingResends() {
        lock.lock(); alwaysRequestResend = true; lock.unlock()
    }

    /// What the simulated machine believes about itself, for tests to assert on.
    public struct Snapshot: Equatable, Sendable {
        public var position: PositionReport
        public var homedAxes: Set<PrinterAxis>
        public var relativeMoves: Bool
        public var relativeExtrusion: Bool
        public var hotendTarget: Double
        public var bedTarget: Double
    }

    public var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            position: position,
            homedAxes: homedAxes,
            relativeMoves: relativeMoves,
            relativeExtrusion: relativeExtrusion,
            hotendTarget: hotendTarget,
            bedTarget: bedTarget
        )
    }

    private func finish(error: SerialError?) {
        lock.lock()
        guard opened else { lock.unlock(); return }
        opened = false
        physicsTimer?.cancel(); physicsTimer = nil
        autoreportTimer?.cancel(); autoreportTimer = nil
        lock.unlock()

        eventSink.yield(.closed(error))
        eventSink.finish()
    }

    private func emit(_ line: String) {
        guard isOpen else { return }
        eventSink.yield(.data(Array((line + "\n").utf8)))
    }

    // MARK: - Command handling

    private func process(_ rawLine: String) {
        lock.lock()
        commandsReceived += 1
        let count = commandsReceived
        let disconnectAt = behaviour.disconnectAfterCommands
        lock.unlock()

        if let disconnectAt, count > disconnectAt {
            simulateUnplug()
            return
        }

        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        // Split `N12 G1 X10*54` into its parts.
        var body = line
        var lineNumber: Int?
        var providedChecksum: UInt8?

        if let star = body.lastIndex(of: "*") {
            providedChecksum = UInt8(body[body.index(after: star)...].trimmingCharacters(in: .whitespaces))
            body = String(body[body.startIndex..<star])
        }
        let payloadForChecksum = body
        if body.hasPrefix("N") {
            let digits = body.dropFirst().prefix { $0.isNumber }
            lineNumber = Int(digits)
            body = String(body.dropFirst(1 + digits.count)).trimmingCharacters(in: .whitespaces)
        }

        // Emergency commands are handled before any validation, as the real
        // emergency parser does — that is the whole point of it.
        if body.hasPrefix("M112") {
            emit("echo:Emergency stop")
            emit("Error:Printer halted. kill() called!")
            return
        }

        if let lineNumber {
            if !validate(lineNumber: lineNumber, body: payloadForChecksum, checksum: providedChecksum) { return }
        }

        respond(to: body, lineNumber: lineNumber)
    }

    /// Returns false when a resend was requested and the command must be ignored.
    private func validate(lineNumber: Int, body: String, checksum: UInt8?) -> Bool {
        lock.lock()
        let validating = behaviour.validateChecksums
        let corruptTarget = behaviour.corruptLineOnce
        let alreadyCorrupted = corruptionUsed
        let refuseEverything = alwaysRequestResend
        lock.unlock()

        // M110 resets the counter and is always accepted.
        if body.contains("M110") {
            lock.lock(); expectedLineNumber = lineNumber + 1; lock.unlock()
            emit(okLine())
            return false
        }

        if refuseEverything {
            emit("Error:checksum mismatch, Last Line: \(lineNumber - 1)")
            emit("Resend: \(lineNumber)")
            emit(okLine())
            return false
        }

        // Fault injection: pretend this line arrived mangled.
        if let corruptTarget, corruptTarget == lineNumber, !alreadyCorrupted {
            lock.lock(); corruptionUsed = true; lock.unlock()
            emit("Error:checksum mismatch, Last Line: \(lineNumber - 1)")
            emit("Resend: \(lineNumber)")
            emit(okLine())
            return false
        }

        if validating {
            if let checksum, checksum != MarlinConnection.checksum(of: body) {
                lock.lock(); let last = expectedLineNumber - 1; lock.unlock()
                emit("Error:checksum mismatch, Last Line: \(last)")
                emit("Resend: \(last + 1)")
                emit(okLine())
                return false
            }
            lock.lock()
            let expected = expectedLineNumber
            lock.unlock()
            if lineNumber != expected {
                // Marlin tolerates a repeat of the line it just accepted.
                if lineNumber == expected - 1 { emit(okLine()); return false }
                emit("Error:Line Number is not Last Line Number+1, Last Line: \(expected - 1)")
                emit("Resend: \(expected)")
                emit(okLine())
                return false
            }
        }

        lock.lock(); expectedLineNumber = lineNumber + 1; lock.unlock()
        return true
    }

    private func respond(to command: String, lineNumber: Int?) {
        let code = command.uppercased()

        switch true {
        case code.hasPrefix("M115"):
            emitFirmwareReport()

        case code.hasPrefix("M105"):
            emit("\(okLine()) \(temperatureFields())")
            return

        case code.hasPrefix("M155"):
            let seconds = intValue(after: "S", in: code) ?? 0
            setAutoreport(seconds: seconds)

        case code.hasPrefix("M114"):
            lock.lock(); let p = position; lock.unlock()
            emit(String(
                format: "X:%.2f Y:%.2f Z:%.2f E:%.2f Count X:%.0f Y:%.0f Z:%.0f",
                p.x ?? 0, p.y ?? 0, p.z ?? 0, p.e ?? 0, (p.x ?? 0) * 80, (p.y ?? 0) * 80, (p.z ?? 0) * 400
            ))

        case code.hasPrefix("M104"), code.hasPrefix("M109"):
            if let target = doubleValue(after: "S", in: code) {
                lock.lock(); hotendTarget = target; lock.unlock()
            }
            if code.hasPrefix("M109") { simulateWaitForHotend(); return }

        case code.hasPrefix("M140"), code.hasPrefix("M190"):
            if let target = doubleValue(after: "S", in: code) {
                lock.lock(); bedTarget = target; lock.unlock()
            }
            if code.hasPrefix("M190") { simulateWaitForBed(); return }

        case code.hasPrefix("G28"):
            simulateHoming(code)
            return

        case code.hasPrefix("G0"), code.hasPrefix("G1"):
            applyMove(code)

        case code.hasPrefix("G90"):
            lock.lock(); relativeMoves = false; lock.unlock()

        case code.hasPrefix("G91"):
            lock.lock(); relativeMoves = true; lock.unlock()

        case code.hasPrefix("M82"):
            lock.lock(); relativeExtrusion = false; lock.unlock()

        case code.hasPrefix("M83"):
            lock.lock(); relativeExtrusion = true; lock.unlock()

        case code.hasPrefix("G92"):
            // G92 sets the current position outright, whatever mode we are in.
            applySetPosition(code)

        case code.hasPrefix("M84"), code.hasPrefix("M18"):
            // The steppers are released, so the axes can be pushed by hand and the
            // firmware's idea of where they are stops being trustworthy.
            lock.lock(); homedAxes.removeAll(); lock.unlock()

        default:
            break
        }

        emit(okLine())
    }

    private func emitFirmwareReport() {
        lock.lock()
        let b = behaviour
        lock.unlock()
        emit("FIRMWARE_NAME:\(b.firmwareName) SOURCE_CODE_URL:https://github.com/MarlinFirmware/Marlin "
           + "PROTOCOL_VERSION:1.0 MACHINE_TYPE:\(b.machineType) EXTRUDER_COUNT:\(b.extruderCount) "
           + "UUID:cede2a2f-41a2-4748-9b12-c55c62f367ff")
        for (name, enabled) in b.capabilities.sorted(by: { $0.key < $1.key }) {
            emit("Cap:\(name):\(enabled ? 1 : 0)")
        }
    }

    private func simulateHoming(_ code: String) {
        let named = PrinterAxis.allCases.filter { code.contains($0.rawValue) }
        // A bare `G28` homes everything.
        let axes = named.isEmpty ? PrinterAxis.allCases : named
        if behaviour.emitBusyForLongCommands { emit("echo:busy: processing") }

        lock.lock()
        for axis in axes {
            switch axis {
            case .x: position.x = 0
            case .y: position.y = 0
            case .z: position.z = 0
            }
            homedAxes.insert(axis)
        }
        lock.unlock()

        emit(okLine())
    }

    private func simulateWaitForHotend() {
        // Real firmware emits busy keepalives then a single `ok`. Jump the temperature
        // to target so tests do not have to wait out simulated physics.
        if behaviour.emitBusyForLongCommands { emit("echo:busy: processing") }
        lock.lock(); hotend = hotendTarget; lock.unlock()
        emit(okLine())
    }

    private func simulateWaitForBed() {
        if behaviour.emitBusyForLongCommands { emit("echo:busy: processing") }
        lock.lock(); bed = bedTarget; lock.unlock()
        emit(okLine())
    }

    /// Applies a `G0`/`G1`, honouring `G90`/`G91` for the axes and `M82`/`M83` for the
    /// extruder — a host that got relative mode wrong would look fine against a mock
    /// that treated every move as absolute, and then jog the real machine into its frame.
    private func applyMove(_ code: String) {
        lock.lock(); defer { lock.unlock() }

        func moved(_ current: Double?, _ requested: Double, relative: Bool) -> Double {
            relative ? (current ?? 0) + requested : requested
        }

        if let x = doubleValue(after: "X", in: code) { position.x = moved(position.x, x, relative: relativeMoves) }
        if let y = doubleValue(after: "Y", in: code) { position.y = moved(position.y, y, relative: relativeMoves) }
        if let z = doubleValue(after: "Z", in: code) { position.z = moved(position.z, z, relative: relativeMoves) }
        if let e = doubleValue(after: "E", in: code) { position.e = moved(position.e, e, relative: relativeExtrusion) }
    }

    /// `G92` — redefine the current position without moving.
    private func applySetPosition(_ code: String) {
        lock.lock(); defer { lock.unlock() }
        if let x = doubleValue(after: "X", in: code) { position.x = x }
        if let y = doubleValue(after: "Y", in: code) { position.y = y }
        if let z = doubleValue(after: "Z", in: code) { position.z = z }
        if let e = doubleValue(after: "E", in: code) { position.e = e }
    }

    private func okLine() -> String {
        lock.lock()
        let advanced = behaviour.advancedOk
        let next = expectedLineNumber - 1
        lock.unlock()
        return advanced ? "ok N\(next) P15 B4" : "ok"
    }

    private func temperatureFields() -> String {
        lock.lock()
        let values = (hotend, hotendTarget, bed, bedTarget)
        lock.unlock()
        return String(format: "T:%.2f /%.2f B:%.2f /%.2f @:0 B@:0",
                      values.0, values.1, values.2, values.3)
    }

    // MARK: - Simulated physics

    private func startPhysics() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.stepPhysics(0.25) }
        lock.lock(); physicsTimer = timer; lock.unlock()
        timer.resume()
    }

    private func stepPhysics(_ dt: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        hotend = approach(hotend, target: hotendTarget, rate: behaviour.hotendHeatingRate, dt: dt)
        bed = approach(bed, target: bedTarget, rate: behaviour.bedHeatingRate, dt: dt)
    }

    private func approach(_ value: Double, target: Double, rate: Double, dt: TimeInterval) -> Double {
        let goal = target > 0 ? target : behaviour.ambientTemperature
        let step = (target > 0 && goal > value ? rate : behaviour.coolingRate) * dt
        if abs(goal - value) <= step { return goal }
        return value + (goal > value ? step : -step)
    }

    private func setAutoreport(seconds: Int) {
        lock.lock()
        autoreportTimer?.cancel()
        autoreportTimer = nil
        autoreportInterval = seconds
        lock.unlock()

        guard seconds > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.behaviour.garbledAutoreport {
                self.emit(self.duplicatedTemperatureFields())
            } else {
                self.emit(" \(self.temperatureFields())")
            }
        }
        lock.lock(); autoreportTimer = timer; lock.unlock()
        timer.resume()
    }

    /// The corrupted form real hardware produces when Marlin writes the auto-report to
    /// two serial ports that resolve to the same UART: each emitted chunk appears twice.
    private func duplicatedTemperatureFields() -> String {
        lock.lock()
        let values = (hotend, hotendTarget, bed, bedTarget)
        lock.unlock()

        func twice(_ text: String) -> String { text + text }
        func number(_ value: Double) -> String { twice(String(format: "%.2f", value)) }

        return "  " + twice("T") + twice(":") + number(values.0)
             + "  " + twice("/") + number(values.1)
             + "  " + twice("B") + twice(":") + number(values.2)
             + "  " + twice("/") + number(values.3)
             + "  " + twice("@") + twice(":") + twice("0")
             + "  " + twice("B@") + twice(":") + twice("0")
    }

    // MARK: - Tiny G-code value scanner

    private func doubleValue(after letter: Character, in code: String) -> Double? {
        guard let index = code.firstIndex(of: letter) else { return nil }
        let rest = code[code.index(after: index)...]
        let digits = rest.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        return Double(digits)
    }

    private func intValue(after letter: Character, in code: String) -> Int? {
        doubleValue(after: letter, in: code).map { Int($0) }
    }
}
