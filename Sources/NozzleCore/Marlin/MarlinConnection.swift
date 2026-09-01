import Foundation

// MARK: - Public surface

public enum CommandPriority: Int, Sendable, Comparable {
    /// The G-code stream of a print job.
    case normal = 0
    /// Interactive things the user is waiting on: jogging, setting a temperature,
    /// `M105` polls. Overtakes the print stream so the UI stays responsive.
    case high = 1

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum MarlinLinkState: Equatable, Sendable {
    case disconnected
    case connecting
    /// Port is open; waiting for the boot banner and identifying the firmware.
    case handshaking
    case ready
    case failed(String)
}

public enum MarlinError: Error, LocalizedError, Sendable, Equatable {
    case notConnected
    case alreadyConnected
    case connectionLost(String)
    case commandTimedOut(String)
    case printerHalted(String)
    case tooManyResends
    case cancelled
    /// The printer acknowledged a query but said nothing Nozzle could read.
    case unreadableReply(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:            return "Not connected to a printer."
        case .alreadyConnected:        return "Already connected."
        case .connectionLost(let why): return "Connection lost: \(why)"
        case .commandTimedOut(let c):  return "The printer stopped responding while running \(c)."
        case .printerHalted(let why):  return "The printer halted itself: \(why). Power-cycle the printer before continuing."
        case .tooManyResends:          return "Too many transmission errors. Try a lower baud rate or a different USB cable."
        case .cancelled:               return "Command cancelled."
        case .unreadableReply(let c):  return "The printer answered \(c) with something Nozzle could not read."
        }
    }
}

public enum MarlinEvent: Sendable {
    case linkState(MarlinLinkState)
    case traffic(TrafficEntry)
    case temperature(TemperatureReport)
    case position(PositionReport)
    case firmware(FirmwareInfo)
    /// A non-fatal `Error:` line from the firmware.
    case firmwareError(String)
    /// The printer is working on a long command and is still alive.
    case busy(Bool)
    /// `//action:` host action command.
    case action(String)
    /// The board rebooted while we thought we were connected. Everything the host
    /// believed about position, homing and heater targets is now wrong.
    case printerReset
}

public struct MarlinConfiguration: Sendable {
    /// Prefix commands with `N<line>` and a checksum. Required for resend recovery;
    /// there is no good reason to turn this off except protocol debugging.
    public var useLineNumbersAndChecksums = true

    /// How many commands may be unacknowledged at once.
    ///
    /// Default 1 — strict send-and-wait, the same thing Pronterface and OctoPrint do
    /// out of the box. Larger windows are faster but are the classic cause of serial
    /// buffer overruns and corrupted prints, so widening this is an opt-in experiment.
    public var maxInFlightCommands = 1

    public var temperaturePollInterval: TimeInterval = 2.0
    public var commandTimeout: TimeInterval = 15.0
    /// Heating and homing legitimately take minutes.
    public var longCommandTimeout: TimeInterval = 600.0
    /// If the printer says nothing at all for this long, stop claiming it is connected.
    public var silenceTimeout: TimeInterval = 30.0
    /// How long to wait for a *parseable* auto-report before giving up on `M155` and
    /// falling back to polling. Advertising the capability is not proof it works.
    public var autoreportVerificationTimeout: TimeInterval = 6.0
    public var startBannerTimeout: TimeInterval = 3.0
    public var resendHistoryDepth = 512
    public var maxConsecutiveResends = 20

    public init() {}
}

// MARK: - Connection

/// The Marlin host protocol: command queue, line numbers, checksums, resend recovery,
/// acknowledgement tracking, timeouts and temperature reporting.
///
/// An actor, so all protocol state is mutated on exactly one execution context and the
/// UI can never race it. It talks to a `SerialTransport` and knows nothing about SwiftUI.
public actor MarlinConnection {

    // MARK: Stored state

    private let transport: SerialTransport
    private var configuration: MarlinConfiguration
    private let parser = MarlinResponseParser()

    /// `nonisolated` so observers can start iterating without hopping onto the actor —
    /// the stream itself is Sendable and needs no protection.
    public nonisolated let events: AsyncStream<MarlinEvent>
    private nonisolated let eventSink: AsyncStream<MarlinEvent>.Continuation

    private var assembler = LineAssembler()
    private var linkState: MarlinLinkState = .disconnected

    private var pending: [PendingCommand] = []
    private var inFlight: [PendingCommand] = []

    private var nextLineNumber = 1
    private var lastAssignedLineNumber = 0
    private var history: [Int: String] = [:]
    private var consecutiveResends = 0
    /// Marlin answers a resend request with `Resend: N` *followed by an `ok`*. That `ok`
    /// means "I am ready for the replay" — it does not acknowledge any queued command.
    /// Crediting it to one would complete a command the printer never ran.
    private var awaitingResendReadyAck = false
    /// If a fork omits that `ok`, replay anyway rather than stalling forever.
    private var resendReadyDeadline: Date?

    private var firmwareInfo: FirmwareInfo?
    private var accumulatingFirmware: FirmwareInfo?
    /// The most recent `M114` answer, kept so `queryPosition()` can hand it back to a
    /// caller that needs the number rather than an event.
    private var lastPosition: PositionReport?
    private var autoreportActive = false
    /// Set when `M155` has been enabled but no intact auto-report has arrived yet.
    /// Some Creality builds advertise `AUTOREPORT_TEMP` and then emit every chunk twice
    /// (`TT::25.9125.91`), which is unparseable — the readout would silently freeze.
    private var autoreportProbationDeadline: Date?

    private var sawStartBanner = false
    private var lastReceiveTime = Date()
    private var lastBusyTime: Date?
    private var reportedBusy = false

    private var readerTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    // MARK: Init

    public init(transport: SerialTransport, configuration: MarlinConfiguration = MarlinConfiguration()) {
        self.transport = transport
        self.configuration = configuration
        let (stream, continuation) = AsyncStream<MarlinEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.eventSink = continuation
    }

    public var state: MarlinLinkState { linkState }
    public var firmware: FirmwareInfo? { firmwareInfo }
    public var isTemperatureAutoreporting: Bool { autoreportActive }
    public var portDescription: String { transport.displayPath }

    // MARK: - Connect / disconnect

    /// Opens the port and identifies the firmware.
    ///
    /// Connecting is a handshake, not just "the file descriptor opened": most Creality
    /// boards reset when DTR is asserted on open, so we wait for the `start` banner,
    /// reset the line counter, then ask `M115` who we are talking to. Only once `M115`
    /// has been acknowledged do we report `.ready`.
    public func connect() async throws {
        guard linkState == .disconnected || isFailed else { throw MarlinError.alreadyConnected }

        resetProtocolState()
        setLinkState(.connecting)
        note("Opening \(transport.displayPath)…")

        do {
            try transport.open()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            setLinkState(.failed(message))
            throw error
        }

        startReaderTask()
        setLinkState(.handshaking)

        // The board is probably rebooting because we just asserted DTR. Give it a
        // moment to announce itself; carry on regardless if it was already running.
        await waitForStartBanner()

        // Terminate any half-transmitted line left in the adapter before the first
        // real command, so M110 is not glued onto the tail of something else.
        try? transport.write([0x0A])

        do {
            // Line numbering must start from a known value on both sides.
            try await resetLineNumberCounter()
            try await send("M115", priority: .high, timeout: 10)
        } catch {
            note("The printer did not answer M115. It may be at a different baud rate.", .warning)
            await teardown(reason: "No response to M115 — check the baud rate.", asFailure: true)
            throw MarlinError.connectionLost("No response to M115.")
        }

        // Prefer firmware-driven temperature reports: they cost no queue slots and so
        // cannot delay the print stream the way polling M105 can.
        if firmwareInfo?.supports(.autoreportTemperature) == true {
            let seconds = max(1, Int(configuration.temperaturePollInterval.rounded()))
            try? await send("M155 S\(seconds)", priority: .high, timeout: 5)
            autoreportActive = true
            autoreportProbationDeadline = Date().addingTimeInterval(configuration.autoreportVerificationTimeout)
            note("Enabled firmware temperature auto-reporting (M155 S\(seconds)); checking it arrives intact…")
        } else {
            let interval = String(format: "%.1f", currentPollInterval())
            note("Firmware has no auto-reporting; polling with M105 every \(interval)s.")
        }

        setLinkState(.ready)
        startWatchdogTask()
        startPollTask()

        try? await send("M105", priority: .high, timeout: 5)
    }

    /// Clean, host-initiated disconnect.
    public func disconnect() async {
        guard linkState != .disconnected else { return }
        if autoreportActive {
            // Stop the firmware talking to a port nobody is listening on.
            try? transport.write(Array("\nM155 S0\n".utf8))
        }
        await teardown(reason: "Disconnected.", asFailure: false)
    }

    private var isFailed: Bool {
        if case .failed = linkState { return true }
        return false
    }

    // MARK: - Sending

    /// Sends a command and waits for the printer's `ok`.
    ///
    /// - Parameter timeout: overrides the automatic timeout. Heating and homing get a
    ///   long one automatically; see `timeout(for:)`.
    public func send(
        _ command: String,
        priority: CommandPriority = .normal,
        timeout: TimeInterval? = nil
    ) async throws {
        let trimmed = Self.sanitise(command)
        guard !trimmed.isEmpty else { return }
        guard canAcceptCommands else { throw MarlinError.notConnected }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let record = PendingCommand(
                text: trimmed,
                priority: priority,
                timeout: timeout ?? self.timeout(for: trimmed),
                continuation: continuation
            )
            enqueue(record)
            pump()
        }
    }

    /// Queues a command without waiting for its `ok`. Errors surface as events.
    public func enqueue(_ command: String, priority: CommandPriority = .normal) {
        let trimmed = Self.sanitise(command)
        guard !trimmed.isEmpty, canAcceptCommands else { return }
        enqueue(PendingCommand(text: trimmed, priority: priority, timeout: timeout(for: trimmed), continuation: nil))
        pump()
    }

    /// Writes straight to the port, bypassing the queue, line numbers and checksums.
    ///
    /// Only for Marlin's emergency commands (`M112`, `M108`, `M410`), which the
    /// firmware's emergency parser scans for in the raw receive buffer. Everything
    /// else must go through the queue or line numbering desynchronises.
    ///
    /// Note that without `Cap:EMERGENCY_PARSER:1` these are *not* immediate — the
    /// firmware only sees them once the command buffer drains. Callers must check
    /// `firmware?.supports(.emergencyParser)` before promising the user otherwise.
    public func sendImmediate(_ command: String) throws {
        guard transport.isOpen else { throw MarlinError.notConnected }
        let trimmed = Self.sanitise(command)
        guard !trimmed.isEmpty else { return }
        // The leading newline terminates any partially transmitted line.
        try transport.write(Array("\n\(trimmed)\n".utf8))
        log(.tx, "\(trimmed)   (immediate, no line number)")
    }

    /// Asks the printer where the nozzle actually is, and waits for the answer.
    ///
    /// `M400` goes first. `M114` on its own reports the position at the *end* of
    /// everything Marlin has already accepted into its motion planner, so asking
    /// straight after a move returns the destination rather than the current location —
    /// and pausing a print on that number would put the nozzle back in the wrong place.
    /// `M400` does not acknowledge until the planner has drained, so what follows it is
    /// the truth.
    ///
    /// The reply arrives as a line *before* its `ok`, in the same way `M115`'s
    /// capability lines do, so by the time the `send` returns it has already been
    /// parsed and stored.
    public func queryPosition() async throws -> PositionReport {
        lastPosition = nil
        try await send("M400", priority: .high)
        try await send("M114", priority: .high)
        guard let lastPosition else { throw MarlinError.unreadableReply("M114") }
        return lastPosition
    }

    public func updateConfiguration(_ configuration: MarlinConfiguration) {
        self.configuration = configuration
    }

    /// Drops everything not yet sent. In-flight commands still need their `ok`.
    /// Used when cancelling a print.
    public func clearQueue() {
        let dropped = pending
        pending.removeAll()
        for command in dropped { command.fail(MarlinError.cancelled) }
        if !dropped.isEmpty { note("Cleared \(dropped.count) queued command(s).") }
    }

    public var queueDepth: Int { pending.count + inFlight.count }

    private var canAcceptCommands: Bool {
        linkState == .ready || linkState == .handshaking
    }

    // MARK: - Queue mechanics

    private func enqueue(_ record: PendingCommand) {
        // Stable priority insertion: high-priority commands go ahead of normal ones
        // but never ahead of another high-priority command already waiting.
        if record.priority == .high,
           let index = pending.firstIndex(where: { $0.priority < record.priority }) {
            pending.insert(record, at: index)
        } else {
            pending.append(record)
        }
    }

    private func pump() {
        while inFlight.count < max(1, configuration.maxInFlightCommands), !pending.isEmpty {
            let record = pending.removeFirst()

            if configuration.useLineNumbersAndChecksums && record.lineNumber == nil {
                let number = nextLineNumber
                nextLineNumber += 1
                lastAssignedLineNumber = number
                record.lineNumber = number
                remember(number, record.text)
            }

            let wire = wireFormat(record)
            do {
                try transport.write(Array((wire + "\n").utf8))
            } catch {
                record.fail(error)
                Task { await self.teardown(reason: "Write failed: \(error.localizedDescription)", asFailure: true) }
                return
            }

            record.sentAt = Date()
            record.attempts += 1
            inFlight.append(record)
            log(.tx, wire)
        }
    }

    private func wireFormat(_ record: PendingCommand) -> String {
        guard configuration.useLineNumbersAndChecksums, let number = record.lineNumber else {
            return record.text
        }
        let body = "N\(number)\(record.text)"
        return "\(body)*\(Self.checksum(of: body))"
    }

    /// Marlin's checksum: XOR of every byte of `N<line><command>`, excluding the `*`.
    public static func checksum(of payload: String) -> UInt8 {
        var value: UInt8 = 0
        for byte in payload.utf8 { value ^= byte }
        return value
    }

    /// Strips comments and whitespace. Marlin rejects empty lines, and a trailing
    /// `;comment` would be included in the checksum for no benefit.
    static func sanitise(_ command: String) -> String {
        var text = command
        if let semicolon = text.firstIndex(of: ";") {
            text = String(text[text.startIndex..<semicolon])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func remember(_ number: Int, _ text: String) {
        history[number] = text
        let cutoff = number - configuration.resendHistoryDepth
        if cutoff > 0 { history[cutoff] = nil }
    }

    /// Resets Marlin's line counter and ours, and waits for the acknowledgement.
    ///
    /// M110 goes through the normal queue rather than being written raw. Writing it
    /// directly would produce an `ok` that no queued command owns, and the next command
    /// would consume it — leaving every acknowledgement from then on off by one, so the
    /// host would run permanently one command ahead of the printer's buffer.
    ///
    /// It is the one command with a pre-assigned line number: 0, so it is valid no
    /// matter what the firmware last saw.
    private func resetLineNumberCounter() async throws {
        history.removeAll()
        nextLineNumber = 1
        lastAssignedLineNumber = 0

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let record = PendingCommand(
                text: "M110 N0",
                priority: .high,
                timeout: configuration.commandTimeout,
                continuation: continuation
            )
            record.lineNumber = 0
            pending.insert(record, at: 0)
            pump()
        }
    }

    /// Commands that legitimately take a long time before their `ok`.
    private func timeout(for command: String) -> TimeInterval {
        let code = command.uppercased()
        let slow = ["M109", "M190", "M191", "G28", "G29", "G30", "G425", "M303", "M600", "M400", "M420"]
        return slow.contains(where: { code.hasPrefix($0) }) ? configuration.longCommandTimeout : configuration.commandTimeout
    }

    // MARK: - Receiving

    private func startReaderTask() {
        readerTask = Task { [weak self, transport] in
            for await event in transport.events {
                guard let self else { return }
                switch event {
                case .opened:
                    continue
                case .data(let bytes):
                    await self.ingest(bytes)
                case .closed(let error):
                    await self.handleTransportClosed(error)
                }
            }
        }
    }

    private func ingest(_ bytes: [UInt8]) {
        lastReceiveTime = Date()
        for line in assembler.append(bytes) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            log(.rx, line)
            handle(parser.parse(line), raw: line)
        }
    }

    private func handle(_ response: MarlinResponse, raw: String) {
        switch response {
        case .ok(let info):
            handleOk(info)

        case .resend(let line):
            handleResend(from: line)

        case .start:
            sawStartBanner = true
            note("Printer reported: start (the board has just booted).")
            // A reset means the firmware's line counter is back at zero and its
            // command buffer is empty. Anything we thought was in flight is gone.
            if linkState == .ready {
                note("The printer reset unexpectedly. Re-synchronising line numbers.", .warning)
                // A rebooted board has forgotten where its axes are, so the last M114
                // answer is now fiction and must not be handed to anything that plans
                // a move from it.
                lastPosition = nil
                emit(.printerReset)
                failAllCommands(MarlinError.connectionLost("The printer reset."))
                Task { try? await self.resetLineNumberCounter() }
            }

        case .busy:
            lastBusyTime = Date()
            if !reportedBusy { reportedBusy = true; emit(.busy(true)) }

        case .wait:
            break

        case .temperature(let report):
            // Only a standalone report proves auto-reporting works; the reply to our own
            // M105 arrives attached to an `ok` and goes through `handleOk` instead.
            if autoreportProbationDeadline != nil {
                autoreportProbationDeadline = nil
                note("Firmware temperature auto-reporting confirmed working.")
            }
            emit(.temperature(report))

        case .position(let report):
            lastPosition = report
            emit(.position(report))

        case .firmware(let info):
            accumulatingFirmware = info

        case .capability(let name, let enabled):
            if accumulatingFirmware != nil {
                accumulatingFirmware?.capabilities[name] = enabled
                accumulatingFirmware?.rawLines.append(raw)
            }

        case .error(let message):
            handleFirmwareError(message)

        case .action(let action):
            emit(.action(action))

        case .echo, .unknown:
            break
        }
    }

    private func handleOk(_ info: OkInfo) {
        if reportedBusy { reportedBusy = false; emit(.busy(false)) }
        lastBusyTime = nil

        if let temperature = info.temperature, !temperature.isEmpty {
            emit(.temperature(temperature))
        }

        // The "ready for your replay" ack. Consume it and start resending; do not let
        // it complete a command.
        if awaitingResendReadyAck {
            awaitingResendReadyAck = false
            resendReadyDeadline = nil
            pump()
            return
        }

        consecutiveResends = 0

        // M115's `Cap:` lines all arrive before its `ok`; commit them now.
        if let accumulated = accumulatingFirmware {
            firmwareInfo = accumulated
            accumulatingFirmware = nil
            emit(.firmware(accumulated))
            describeFirmware(accumulated)
        }

        guard !inFlight.isEmpty else {
            // An `ok` we did not ask for — usually left over from before we connected.
            return
        }
        let completed = inFlight.removeFirst()
        completed.complete()
        pump()
    }

    /// Marlin flushes its command buffer when it asks for a resend, so everything we
    /// believed was in flight has been discarded and must be replayed from `line`.
    private func handleResend(from line: Int) {
        guard configuration.useLineNumbersAndChecksums else {
            note("Printer asked to resend line \(line), but line numbering is disabled.", .warning)
            return
        }

        consecutiveResends += 1
        guard consecutiveResends <= configuration.maxConsecutiveResends else {
            note("Giving up after \(consecutiveResends) consecutive resend requests.", .warning)
            failAllCommands(MarlinError.tooManyResends)
            Task { await self.teardown(reason: "Too many transmission errors.", asFailure: true) }
            return
        }

        note("Printer requested resend from line \(line) — replaying.", .warning)

        // Keep the original records (and their continuations) where we still have them,
        // so an awaited command survives a resend instead of hanging or double-resuming.
        var byLine: [Int: PendingCommand] = [:]
        for command in inFlight {
            if let number = command.lineNumber { byLine[number] = command }
        }
        inFlight.removeAll()

        var replay: [PendingCommand] = []
        if line <= lastAssignedLineNumber {
            for number in line...lastAssignedLineNumber {
                if let existing = byLine.removeValue(forKey: number) {
                    existing.sentAt = nil
                    replay.append(existing)
                } else if let text = history[number] {
                    let rebuilt = PendingCommand(
                        text: text, priority: .high, timeout: timeout(for: text), continuation: nil
                    )
                    rebuilt.lineNumber = number
                    replay.append(rebuilt)
                } else {
                    // Older than our history window: unrecoverable without restarting
                    // the job. Better to stop than to send the printer the wrong line.
                    note("Cannot resend line \(number): outside the history buffer.", .warning)
                    failAllCommands(MarlinError.tooManyResends)
                    Task { await self.teardown(reason: "Resend requested for a line we no longer have.", asFailure: true) }
                    return
                }
            }
        }

        // Anything in flight the printer did *not* ask for was accepted already.
        for leftover in byLine.values { leftover.complete() }

        pending.insert(contentsOf: replay, at: 0)
        // Deliberately no pump() here: wait for Marlin's post-Resend `ok`, which is its
        // signal that it has flushed its buffer and is ready to receive the replay.
        awaitingResendReadyAck = true
        resendReadyDeadline = Date().addingTimeInterval(2.0)
    }

    private func handleFirmwareError(_ message: String) {
        emit(.firmwareError(message))

        // These mean Marlin has called kill() — it will never send another `ok`, and
        // pretending otherwise would leave the UI showing a print that is not happening.
        let fatal = ["halted", "kill", "thermal runaway", "heating failed",
                     "maxtemp", "mintemp", "thermistor", "printer stopped"]
        let lower = message.lowercased()
        if fatal.contains(where: { lower.contains($0) }) {
            note("Fatal firmware error: \(message)", .warning)
            failAllCommands(MarlinError.printerHalted(message))
            Task { await self.teardown(reason: message, asFailure: true) }
        }
    }

    private func describeFirmware(_ info: FirmwareInfo) {
        var parts: [String] = []
        if let name = info.firmwareName { parts.append(name) }
        if let machine = info.machineType { parts.append("on \(machine)") }
        note("Identified: \(parts.isEmpty ? "unknown firmware" : parts.joined(separator: " "))")
        if !info.supports(.emergencyParser) {
            note("This firmware has no emergency parser: M112 will only take effect once "
               + "queued moves finish. Use the printer's power switch for a true emergency stop.", .warning)
        }
    }

    // MARK: - Handshake helper

    private func waitForStartBanner() async {
        let deadline = Date().addingTimeInterval(configuration.startBannerTimeout)
        while !sawStartBanner && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !sawStartBanner {
            note("No boot banner within \(Int(configuration.startBannerTimeout))s — the printer was probably already running.")
        }
    }

    // MARK: - Background tasks

    private func startWatchdogTask() {
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await self.checkForStalls()
            }
        }
    }

    private func checkForStalls() async {
        guard linkState == .ready else { return }
        let now = Date()

        // A printer that has said nothing at all — not even a temperature report — is
        // not a connected printer, whatever the port thinks.
        if now.timeIntervalSince(lastReceiveTime) > configuration.silenceTimeout {
            note("No data from the printer for \(Int(configuration.silenceTimeout))s.", .warning)
            failAllCommands(MarlinError.connectionLost("The printer stopped responding."))
            await teardown(reason: "The printer stopped responding.", asFailure: true)
            return
        }

        // Auto-reporting was advertised but nothing parseable arrived. Rather than let
        // the temperature readout quietly freeze, go back to polling.
        if autoreportActive, let deadline = autoreportProbationDeadline, now > deadline {
            autoreportProbationDeadline = nil
            autoreportActive = false
            enqueue("M155 S0", priority: .high)
            note("This firmware advertises temperature auto-reporting, but its reports are not "
               + "arriving in a readable form (some Creality builds send every value twice when a "
               + "second serial port is compiled in). Switching to M105 polling instead.", .warning)
        }

        // A firmware fork that does not send `ok` after `Resend:` must not wedge us.
        if awaitingResendReadyAck, let deadline = resendReadyDeadline, now > deadline {
            note("No ready-acknowledgement after the resend request; replaying anyway.", .warning)
            awaitingResendReadyAck = false
            resendReadyDeadline = nil
            pump()
            return
        }

        guard let head = inFlight.first, let sentAt = head.sentAt else { return }
        // `busy: processing` is Marlin saying "still working" — it must postpone the
        // timeout, otherwise every long heat-up would look like a stall.
        let lastSignOfLife = max(sentAt, lastBusyTime ?? sentAt)
        if now.timeIntervalSince(lastSignOfLife) > head.timeout {
            note("No acknowledgement for \(head.text) after \(Int(head.timeout))s.", .warning)
            failAllCommands(MarlinError.commandTimedOut(head.text))
            await teardown(reason: "The printer stopped acknowledging commands.", asFailure: true)
        }
    }

    private func startPollTask() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.currentPollInterval()
                try? await Task.sleep(for: .seconds(interval))
                await self.pollTemperaturesIfNeeded()
            }
        }
    }

    private func currentPollInterval() -> TimeInterval {
        max(0.02, configuration.temperaturePollInterval)
    }

    private func pollTemperaturesIfNeeded() {
        guard linkState == .ready, !autoreportActive else { return }
        // Never stack M105s. If one is already waiting, the printer is busy and adding
        // another would only lengthen the queue ahead of the print stream.
        let alreadyQueued = pending.contains { $0.isTemperaturePoll } || inFlight.contains { $0.isTemperaturePoll }
        guard !alreadyQueued else { return }

        let record = PendingCommand(
            text: "M105", priority: .high, timeout: configuration.commandTimeout, continuation: nil
        )
        record.isTemperaturePoll = true
        enqueue(record)
        pump()
    }

    // MARK: - Teardown

    private func handleTransportClosed(_ error: SerialError?) async {
        guard linkState != .disconnected else { return }
        let reason = error?.localizedDescription ?? "Disconnected."
        failAllCommands(MarlinError.connectionLost(reason))
        await teardown(reason: reason, asFailure: error != nil)
    }

    private func teardown(reason: String, asFailure: Bool) async {
        // Closing the transport makes it emit `.closed`, which routes straight back
        // here. The first call wins — otherwise the follow-up would overwrite
        // `.failed("Thermal runaway")` with a bland `.disconnected` and the user would
        // never learn why the printer stopped.
        guard linkState != .disconnected, !isFailed else { return }

        readerTask?.cancel(); readerTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        pollTask?.cancel(); pollTask = nil

        failAllCommands(MarlinError.connectionLost(reason))
        transport.close()

        assembler.reset()
        autoreportActive = false
        note(reason, asFailure ? .warning : .info)
        setLinkState(asFailure ? .failed(reason) : .disconnected)
    }

    private func failAllCommands(_ error: Error) {
        let all = inFlight + pending
        inFlight.removeAll()
        pending.removeAll()
        for command in all { command.fail(error) }
    }

    private func resetProtocolState() {
        assembler.reset()
        pending.removeAll()
        inFlight.removeAll()
        history.removeAll()
        nextLineNumber = 1
        lastAssignedLineNumber = 0
        consecutiveResends = 0
        awaitingResendReadyAck = false
        resendReadyDeadline = nil
        sawStartBanner = false
        reportedBusy = false
        lastBusyTime = nil
        lastReceiveTime = Date()
        firmwareInfo = nil
        accumulatingFirmware = nil
        lastPosition = nil
        autoreportActive = false
        autoreportProbationDeadline = nil
    }

    // MARK: - Events

    private func setLinkState(_ newState: MarlinLinkState) {
        guard linkState != newState else { return }
        linkState = newState
        emit(.linkState(newState))
    }

    private func emit(_ event: MarlinEvent) {
        eventSink.yield(event)
    }

    private func log(_ direction: TrafficEntry.Direction, _ text: String) {
        emit(.traffic(TrafficEntry(direction: direction, text: text)))
    }

    private func note(_ text: String, _ direction: TrafficEntry.Direction = .info) {
        log(direction, text)
    }
}

// MARK: - Pending command

/// One queued command and, if someone is awaiting it, its continuation.
///
/// A class rather than a struct so that identity survives being moved between the
/// pending and in-flight lists and back again during a resend, and so `continuation`
/// can be nilled out to make double-resumption structurally impossible.
final class PendingCommand {
    let text: String
    let priority: CommandPriority
    let timeout: TimeInterval
    var lineNumber: Int?
    var sentAt: Date?
    var attempts = 0
    var isTemperaturePoll = false

    private var continuation: CheckedContinuation<Void, Error>?

    init(text: String, priority: CommandPriority, timeout: TimeInterval, continuation: CheckedContinuation<Void, Error>?) {
        self.text = text
        self.priority = priority
        self.timeout = timeout
        self.continuation = continuation
    }

    func complete() {
        continuation?.resume()
        continuation = nil
    }

    func fail(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    deinit {
        // Safety net: never leak an un-resumed continuation.
        continuation?.resume(throwing: MarlinError.cancelled)
    }
}
