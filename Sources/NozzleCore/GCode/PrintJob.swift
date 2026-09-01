import Foundation

/// Where a running print has got to.
public struct PrintProgress: Equatable, Sendable {
    public var commandsSent: Int = 0
    public var commandCount: Int = 0
    /// Index into the file's `lines`, so the UI can show the command being run.
    public var lineIndex: Int = 0
    public var layerIndex: Int?
    public var layerCount: Int = 0
    public var startedAt: Date?
    /// From the slicer's per-layer timings, not from lines-sent. `nil` when the file
    /// carries no timings — in which case saying nothing beats inventing a number.
    public var estimatedRemaining: TimeInterval?

    /// How long the print has spent paused, in total.
    ///
    /// Kept separately so the remaining-time estimate — which comes from the slicer and
    /// therefore assumes no pauses — is not quietly contradicted by the elapsed clock.
    public var pausedDuration: TimeInterval = 0

    /// 0…1. Time-based where the file allows it, otherwise by commands sent.
    public var fraction: Double = 0

    public init() {}

    public var elapsed: TimeInterval? {
        guard let startedAt else { return nil }
        return Date().timeIntervalSince(startedAt)
    }

    /// Elapsed time with the pauses taken out — the figure comparable to the slicer's
    /// estimate, since that estimate only ever counted printing.
    public var printingTime: TimeInterval? {
        elapsed.map { max(0, $0 - pausedDuration) }
    }
}

public enum PrintJobPhase: Equatable, Sendable {
    case idle
    case printing
    /// Pause requested; the nozzle is being retracted, lifted and parked.
    case pausing
    /// Parked and waiting. The heaters are still on.
    case paused
    /// Returning to where the file left off, before the stream restarts.
    case resuming
    case finished
    case cancelled
    case failed(String)

    /// The job is alive: streaming, or somewhere in the pause dance.
    public var isActive: Bool {
        switch self {
        case .printing, .pausing, .paused, .resuming: return true
        case .idle, .finished, .cancelled, .failed:   return false
        }
    }

    /// Commands from the file are going out right now.
    public var isStreaming: Bool { self == .printing }

    /// The job is over, one way or another.
    public var isTerminal: Bool {
        switch self {
        case .finished, .cancelled, .failed: return true
        default:                             return false
        }
    }
}

public enum PrintJobEvent: Sendable {
    case phase(PrintJobPhase)
    case progress(PrintProgress)
    /// Emitted once per layer so the UI can react without polling.
    case layer(Int)
    /// Something worth telling the user in plain English, but not an error.
    case note(String)
}

/// Streams a loaded file to the printer, one command at a time.
///
/// Deliberately the dullest possible loop: send a line, wait for its `ok`, send the
/// next. That is what Pronterface and OctoPrint do, and the reason is that the printer's
/// own command buffer is small — running ahead of it is the classic cause of a corrupted
/// print. `MarlinConnection` already enforces the window; this type only decides *what*
/// to send and keeps track of where it has got to.
///
/// An actor so progress cannot be read halfway through being written. Pause, resume and
/// stop are all methods on it, and they work by setting a flag the streaming loop reads
/// between commands — actor reentrancy means they run while `run()` is suspended waiting
/// for an `ok`, and the loop notices as soon as that `ok` arrives.
public actor PrintJob {

    public let file: GCodeFile
    private let connection: MarlinConnection
    private let profile: PrinterProfile

    public nonisolated let events: AsyncStream<PrintJobEvent>
    private nonisolated let eventSink: AsyncStream<PrintJobEvent>.Continuation

    private var phase: PrintJobPhase = .idle
    private var progress = PrintProgress()
    private var stopRequested = false
    private var pauseRequested = false
    private var lastEmitted = Date.distantPast

    /// The modal state the file has put the printer in, rebuilt as each line goes out.
    ///
    /// Tracked from what was actually sent rather than replayed from the file, so it
    /// cannot drift from the machine's real state.
    private var modal = GCodeModalState()

    /// Where the nozzle was when the pause began, so resume can put it back.
    private var pausedAt: PositionReport?
    private var pauseBegan: Date?

    /// How often progress is published while printing. Every command would be ~14,000
    /// UI updates for a calibration cube; a quarter-second is smoother and far cheaper.
    private let progressInterval: TimeInterval = 0.25

    /// How often the paused loop checks whether it has been resumed. Nothing is
    /// happening during a pause, so a coarse poll costs nothing and avoids the
    /// double-resume hazards of parking a continuation somewhere.
    private let pausePollInterval: Duration = .milliseconds(200)

    public init(file: GCodeFile, connection: MarlinConnection, profile: PrinterProfile) {
        self.file = file
        self.connection = connection
        self.profile = profile
        let (stream, continuation) = AsyncStream<PrintJobEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.eventSink = continuation

        var initial = PrintProgress()
        initial.commandCount = file.commandCount
        initial.layerCount = file.layerCount
        initial.estimatedRemaining = file.metadata.estimatedDuration
        self.progress = initial
    }

    public var currentPhase: PrintJobPhase { phase }
    public var currentProgress: PrintProgress { progress }
    /// Exposed for tests: what the file has left the printer's modal flags set to.
    var currentModalState: GCodeModalState { modal }

    // MARK: - Running

    /// Sends the whole file. Returns when the print finishes, fails or is stopped.
    public func run() async {
        guard phase == .idle else { return }
        setPhase(.printing)
        progress.startedAt = Date()
        var lastLayer: Int?

        for (position, lineIndex) in file.commandLineIndices.enumerated() {
            if stopRequested { break }

            // Between two commands is the only safe moment to step out of the stream:
            // the previous line has been acknowledged and the next has not been sent,
            // so the printer is doing exactly what the file says and nothing more.
            if pauseRequested {
                await runPause()
                if stopRequested { break }
                if case .failed = phase { return }
            }

            do {
                // Comments and whitespace are stripped by the connection, so a line like
                // `G28 ;Home` goes out as `G28` and is checksummed as such.
                try await connection.send(file.lines[lineIndex], priority: .normal)
            } catch {
                // Stopping empties the queue, which fails whatever was waiting in it.
                // That is the cancellation working, not the print breaking.
                if stopRequested { break }
                setPhase(.failed(describe(error)))
                return
            }

            modal.observe(file.lines[lineIndex])

            progress.commandsSent = position + 1
            progress.lineIndex = lineIndex
            progress.layerIndex = file.layerIndex(atLineIndex: lineIndex)
            progress.estimatedRemaining = file.estimatedRemaining(atLineIndex: lineIndex)
            progress.fraction = fraction(atLineIndex: lineIndex, sent: position + 1)

            if let layer = progress.layerIndex, layer != lastLayer {
                lastLayer = layer
                eventSink.yield(.layer(layer))
                publishProgress(force: true)
            } else {
                publishProgress()
            }
        }

        if stopRequested {
            setPhase(.cancelled)
        } else {
            publishProgress(force: true)
            setPhase(.finished)
        }
    }

    /// Progress by time where the file gives us timings, by commands otherwise.
    ///
    /// Lines are a poor proxy for time — a dense infill layer has many more commands
    /// than a tall thin one — so a lines-based bar visibly stalls and then races.
    private func fraction(atLineIndex index: Int, sent: Int) -> Double {
        if let total = file.metadata.estimatedDuration ?? file.layers.last?.elapsedAtEnd,
           total > 0,
           let elapsed = file.estimatedElapsed(atLineIndex: index) {
            return min(1, max(0, elapsed / total))
        }
        guard progress.commandCount > 0 else { return 0 }
        return min(1, Double(sent) / Double(progress.commandCount))
    }

    private func publishProgress(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastEmitted) >= progressInterval else { return }
        lastEmitted = now
        eventSink.yield(.progress(progress))
    }

    // MARK: - Pause and resume

    /// Asks for the print to pause at the next command boundary.
    ///
    /// Returns as soon as the request is recorded, not when the nozzle has parked — the
    /// printer may be several seconds into a long move, and the UI should say "pausing"
    /// rather than freeze.
    public func pause() {
        guard phase == .printing, !pauseRequested, !stopRequested else { return }
        pauseRequested = true
        setPhase(.pausing)
    }

    /// Carries on from where the pause left off.
    public func resume() {
        guard phase == .paused else { return }
        pauseRequested = false
    }

    public var isPaused: Bool { phase == .paused }

    /// Parks the nozzle, waits to be resumed, then puts it back. Runs inside `run()`.
    private func runPause() async {
        setPhase(.pausing)

        do {
            // Where the file has actually got to. This is the number the whole pause
            // hangs on, so it is read before anything of ours has moved the machine.
            let position = try await connection.queryPosition()
            pausedAt = position

            switch MovePlanner.pausePark(from: position, modal: modal, profile: profile) {
            case .refused(let reason):
                // A pause we cannot reverse is worse than none. Carry on printing and
                // say why, rather than parking with no way back.
                pauseRequested = false
                eventSink.yield(.note("The print could not be paused. \(reason)"))
                setPhase(.printing)
                return
            case .go(let plan):
                if let note = plan.note { eventSink.yield(.note(note)) }
                try await send(plan)
            }
        } catch {
            setPhase(.failed(describe(error)))
            return
        }

        pauseBegan = Date()
        setPhase(.paused)

        // Nothing to react to while parked, so a dull poll is the whole mechanism.
        // The connection keeps polling temperatures throughout, which both keeps the
        // readout live and keeps the link's silence watchdog satisfied.
        while pauseRequested && !stopRequested {
            try? await Task.sleep(for: pausePollInterval)
            publishPausedProgress()
        }

        finishTimingThePause()
        guard !stopRequested else { return }

        setPhase(.resuming)
        switch MovePlanner.resumeReturn(to: pausedAt, modal: modal, profile: profile) {
        case .refused(let reason):
            setPhase(.failed("The print could not be resumed. \(reason)"))
            return
        case .go(let plan):
            do {
                try await send(plan)
            } catch {
                setPhase(.failed(describe(error)))
                return
            }
        }

        pausedAt = nil
        setPhase(.printing)
    }

    /// Keeps the elapsed clock ticking while parked, and accumulates paused time.
    private func publishPausedProgress() {
        guard let pauseBegan else { return }
        var snapshot = progress
        snapshot.pausedDuration += Date().timeIntervalSince(pauseBegan)
        eventSink.yield(.progress(snapshot))
    }

    private func finishTimingThePause() {
        guard let pauseBegan else { return }
        progress.pausedDuration += Date().timeIntervalSince(pauseBegan)
        self.pauseBegan = nil
        publishProgress(force: true)
    }

    // MARK: - Stopping

    /// Stops the print for good and leaves the machine in a safe state.
    ///
    /// Clearing the queue first stops anything else going out. What it cannot do is
    /// empty the printer's *own* motion buffer: every command Marlin has acknowledged
    /// is already planned, so the machine finishes those — a second or so of movement —
    /// before it sees anything sent here. `M112` would not help; on this firmware it has
    /// no emergency parser to jump the queue, and it halts the board until it is
    /// power-cycled. See `MovePlanner.stop(profile:alreadyParked:)`.
    public func stop() async {
        guard phase.isActive else { return }
        let wasParked = (phase == .paused)
        stopRequested = true
        pauseRequested = false

        await connection.clearQueue()

        // Each of these is best-effort: the reason we are stopping may well be that the
        // printer has gone away, and failing to turn off a heater that is already
        // unreachable should not mask the cancellation.
        for command in MovePlanner.stop(profile: profile, alreadyParked: wasParked).commands {
            try? await connection.send(command, priority: .high)
        }
    }

    // MARK: - Helpers

    /// Sends a plan's commands in order at high priority, so they overtake anything the
    /// print stream has left queued.
    private func send(_ plan: MovePlan) async throws {
        for command in plan.commands {
            try await connection.send(command, priority: .high)
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    private func setPhase(_ newPhase: PrintJobPhase) {
        guard phase != newPhase else { return }
        phase = newPhase
        eventSink.yield(.phase(newPhase))
        // Only a terminal phase closes the stream. Pausing is not the end of the job,
        // and finishing the stream there would leave the UI with no way to hear about
        // the resume.
        if newPhase.isTerminal { eventSink.finish() }
    }
}
