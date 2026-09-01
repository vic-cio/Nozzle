import Foundation
import Observation
import NozzleCore

/// The boundary between SwiftUI and the printer.
///
/// Views read `state`, `log` and `profile`, and call methods here. Nothing in the view
/// layer ever touches `SerialTransport` or `MarlinConnection` directly — the only way
/// to reach the port is through an `await` into the actor, which keeps every byte of
/// serial I/O off the main thread and off the UI's timeline.
@MainActor
@Observable
final class PrinterController {

    // MARK: Observable state

    private(set) var state = PrinterState()
    private(set) var log = TrafficLog()
    private(set) var ports: [SerialPortInfo] = []
    private(set) var temperatureHistory: [TemperatureSample] = []

    var profile: PrinterProfile {
        didSet {
            guard profile != oldValue else { return }
            profileStore.save(profile)
        }
    }

    /// Which screen is showing. Lives here rather than in `RootView` so the View menu
    /// can switch sections too.
    var section: MainSection = .print

    /// The port the user picked, or `nil` to auto-select the best candidate.
    var selectedPortPath: String?
    /// Use the built-in simulator instead of real hardware.
    var useDemoPrinter = false
    /// Surfaced as an alert; cleared when acknowledged.
    var lastError: String?

    /// What Nozzle is doing on the user's behalf right now ("Homing…"), or `nil` when
    /// idle. One operation at a time: two overlapping jogs would interleave their
    /// `G91`/`G90` wrappers and the second could run in the wrong coordinate mode.
    private(set) var operation: String?

    /// The last thing Nozzle did differently from what was asked — e.g. shortening a
    /// jog at the edge of the bed. Shown inline on the Prepare screen, not as an alert.
    var lastNote: String?

    /// The file chosen on the Print screen, and what is wrong with it, if anything.
    private(set) var loadedFile: GCodeFile?
    private(set) var fileWarnings: [GCodeWarning] = []
    /// Live position of the running print, or `nil` when nothing is printing.
    private(set) var progress: PrintProgress?
    /// What the print job is doing, in its own terms. `PrinterState.activity` is the
    /// coarse version for the status pill; this drives the Pause/Resume buttons.
    private(set) var jobPhase: PrintJobPhase = .idle

    // MARK: Private

    private let profileStore = PrinterProfileStore()
    private let portMonitor = SerialPortMonitor()
    private var connection: MarlinConnection?
    private var eventTask: Task<Void, Never>?
    private var isConnecting = false
    private var printJob: PrintJob?
    private var jobTask: Task<Void, Never>?
    private let sleepBlocker = SleepBlocker()

    private let maximumTemperatureSamples = 1_800   // ~1 hour at 2 s intervals

    /// Set `NOZZLE_DEMO=1` in the environment to launch straight into the simulated
    /// printer. Handy for looking around the app, and for screenshotting the connected
    /// state without a machine attached.
    let autoConnectOnLaunch: Bool

    init() {
        let loaded = profileStore.load()
        let demo = ProcessInfo.processInfo.environment["NOZZLE_DEMO"] == "1"
        self.profile = loaded
        self.selectedPortPath = loaded.preferredPortPath
        self.autoConnectOnLaunch = demo
        self.useDemoPrinter = demo
        refreshPorts()
        // Plugging the printer in after launch used to leave the picker empty until
        // the user found the Refresh button. Watch for it instead.
        portMonitor.start { [weak self] in self?.portsChangedOnTheirOwn() }
    }

    // MARK: - Ports

    func refreshPorts() {
        ports = SerialPortDiscovery.availablePorts()
        // If the remembered port is gone (printer unplugged), fall back to auto-select
        // rather than leaving a dead path selected in the picker.
        if let selected = selectedPortPath, !ports.contains(where: { $0.path == selected }) {
            selectedPortPath = nil
        }
    }

    /// A device was attached or removed while the app was running.
    ///
    /// Only ever updates the picker. Connecting is left to the user on purpose:
    /// opening the port asserts DTR, which resets a Creality board — not something to
    /// do behind their back, least of all to a printer that is mid-job from SD card.
    private func portsChangedOnTheirOwn() {
        let before = ports
        refreshPorts()
        guard ports.map(\.path) != before.map(\.path) else { return }

        let appeared = ports.filter { port in !before.contains { $0.path == port.path } }
        let vanished = before.filter { port in !ports.contains { $0.path == port.path } }

        // Worth a line in the Console, but only for something that looks like the
        // printer — a phone or a Bluetooth device appearing is noise.
        if let port = appeared.first(where: { $0.score >= 70 }) {
            log.append(TrafficEntry(direction: .info, text: "Serial port appeared: \(port.displayName)"))
        }
        if let port = vanished.first(where: { $0.score >= 70 }) {
            log.append(TrafficEntry(direction: .info, text: "Serial port went away: \(port.displayName)"))
        }
    }

    /// The port a connect attempt would actually use.
    var effectivePort: SerialPortInfo? {
        if let selectedPortPath { return ports.first { $0.path == selectedPortPath } }
        return SerialPortDiscovery.bestGuess(from: ports)
    }

    var canConnect: Bool {
        !state.activity.isConnected && !isConnecting && (useDemoPrinter || effectivePort != nil)
    }

    // MARK: - Connection lifecycle

    func connect() async {
        guard canConnect else { return }
        isConnecting = true
        defer { isConnecting = false }

        let transport: SerialTransport
        let portPath: String

        if useDemoPrinter {
            var behaviour = MockPrinterBehaviour()
            behaviour.responseDelay = 0.01   // feels like a real machine in the UI
            transport = MockMarlinPrinter(behaviour: behaviour)
            portPath = "Demo Printer"
        } else {
            guard let port = effectivePort else {
                lastError = "No serial port selected."
                return
            }
            transport = PosixSerialTransport(path: port.path, baudRate: profile.baudRate)
            portPath = port.path
        }

        state.activity = .connecting
        state.portPath = portPath
        state.baudRate = profile.baudRate

        let connection = MarlinConnection(transport: transport, configuration: profile.marlinConfiguration)
        self.connection = connection
        observe(connection)

        do {
            try await connection.connect()
            if !useDemoPrinter {
                profile.preferredPortPath = portPath
            }
        } catch {
            // `observe` will have received the failure event too; this only makes it
            // visible as an alert rather than a line buried in the Console.
            lastError = error.localizedDescription
        }
    }

    func disconnect() async {
        await connection?.disconnect()
        // The event stream reports the state change; nothing else to do here.
    }

    private func observe(_ connection: MarlinConnection) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in connection.events {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    private func apply(_ event: MarlinEvent) {
        switch event {
        case .linkState(let linkState):
            applyLinkState(linkState)

        case .traffic(let entry):
            log.append(entry)

        case .temperature(let report):
            state.hotend = report.hotend
            state.bed = report.bed
            state.lastTemperatureUpdate = Date()
            recordTemperatureSample()

        case .position(let report):
            state.position = report

        case .firmware(let info):
            state.firmware = info

        case .firmwareError(let message):
            state.lastFirmwareError = message

        case .busy(let busy):
            state.isBusy = busy

        case .action(let action):
            log.append(TrafficEntry(direction: .info, text: "Printer action: \(action)"))

        case .printerReset:
            // The board has rebooted. It has forgotten where its axes are, so we must
            // too — continuing to show "homed" would invite a jog into the frame.
            state.homedAxes = []
            state.position = nil
            lastNote = "The printer restarted, so it no longer knows where its axes are. Home it again "
                     + "before moving anything."
        }
    }

    private func applyLinkState(_ linkState: MarlinLinkState) {
        switch linkState {
        case .disconnected:
            state.activity = .disconnected
            resetVolatileState()
        case .connecting, .handshaking:
            state.activity = .connecting
        case .ready:
            // A job may already be running; connecting never downgrades that.
            if !state.activity.isJobActive { state.activity = .connected }
        case .failed(let reason):
            state.activity = .error(reason)
            resetVolatileState()
            lastError = reason
        }
    }

    /// Forget everything that is only true while a link exists. Showing a stale
    /// temperature next to "Disconnected" would imply the printer is still being watched.
    private func resetVolatileState() {
        state.hotend = nil
        state.bed = nil
        state.position = nil
        state.homedAxes = []
        state.isBusy = false
        state.lastTemperatureUpdate = nil
        lastNote = nil
        connection = nil
    }

    private func recordTemperatureSample() {
        let sample = TemperatureSample(
            time: Date(),
            hotend: state.hotend?.current,
            hotendTarget: state.hotend?.target,
            bed: state.bed?.current,
            bedTarget: state.bed?.target
        )
        temperatureHistory.append(sample)
        if temperatureHistory.count > maximumTemperatureSamples {
            temperatureHistory.removeFirst(temperatureHistory.count - maximumTemperatureSamples)
        }
    }

    // MARK: - Commands

    /// Sends a command typed into the Console.
    func sendConsoleCommand(_ text: String) async {
        guard let connection else {
            lastError = "Not connected."
            return
        }
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        do {
            if CommandSafety.isEmergency(command) {
                try await connection.sendImmediate(command)
            } else {
                try await connection.send(command, priority: .high)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearLog() {
        log.clear()
    }

    // MARK: - Printing

    /// Loads a file and reports anything wrong with it, without sending a byte.
    func loadFile(at url: URL) {
        // The picker hands back a security-scoped URL on a sandboxed launch; the app is
        // unsandboxed today, so this is belt and braces rather than load-bearing.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let file = try GCodeFile.load(contentsOf: url)
            loadedFile = file
            fileWarnings = file.warnings(for: profile)
            log.append(TrafficEntry(
                direction: .info,
                text: "Loaded \(file.name): \(file.commandCount) commands, \(file.layerCount) layers."
            ))
        } catch {
            loadedFile = nil
            fileWarnings = []
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func unloadFile() {
        guard !state.activity.isJobActive else { return }
        loadedFile = nil
        fileWarnings = []
        progress = nil
    }

    /// Why the Print button cannot be pressed, or `nil` when it can.
    var printBlockedReason: String? {
        guard loadedFile != nil else { return "Choose a G-code file first." }
        guard state.activity.isConnected else { return "Connect to the printer first." }
        if state.activity.isJobActive { return "A print is already running." }
        if isBusyWithOperation { return "Wait for the current operation to finish." }
        if let blocking = fileWarnings.first(where: { $0.severity == .blocking }) {
            return blocking.title
        }
        return nil
    }

    func startPrint() async {
        guard printBlockedReason == nil, let file = loadedFile, let connection else { return }

        let job = PrintJob(file: file, connection: connection, profile: profile)
        printJob = job
        state.activity = .printing
        jobPhase = .printing
        progress = PrintProgress()
        // A sleeping Mac stops servicing the USB port, which strands the printer
        // mid-part with a hot nozzle resting on it.
        sleepBlocker.begin(reason: "Printing \(file.name)")
        observeJob(job)

        await job.run()
    }

    /// Parks the nozzle and waits. The heaters stay on so the print can carry on.
    func pausePrint() async {
        guard let printJob, jobPhase == .printing else { return }
        await printJob.pause()
    }

    /// Puts the nozzle back where the file left it and carries on.
    func resumePrint() async {
        guard let printJob, jobPhase == .paused else { return }
        await printJob.resume()
    }

    /// Stops the print for good and parks the machine safely.
    func stopPrint() async {
        await printJob?.stop()
    }

    /// Whether the Pause button should be offered, and why not when it should not be.
    var pauseBlockedReason: String? {
        switch jobPhase {
        case .printing: return nil
        case .pausing:  return "Pausing — finishing the command the printer is on."
        case .paused:   return "The print is already paused."
        case .resuming: return "Getting back to where the print left off."
        default:        return "Nothing is printing."
        }
    }

    private func observeJob(_ job: PrintJob) {
        jobTask?.cancel()
        jobTask = Task { [weak self] in
            for await event in job.events {
                guard let self else { return }
                switch event {
                case .progress(let value):
                    self.progress = value
                case .layer:
                    break   // progress carries the layer; the event is for future use
                case .note(let text):
                    self.lastNote = text
                    self.log.append(TrafficEntry(direction: .info, text: text))
                case .phase(let phase):
                    self.applyJobPhase(phase)
                }
            }
        }
    }

    private func applyJobPhase(_ phase: PrintJobPhase) {
        jobPhase = phase

        switch phase {
        case .idle:
            break
        case .printing, .pausing, .resuming:
            // Still a running print as far as the rest of the app is concerned: the
            // machine is moving and nothing else may be sent to it.
            state.activity = .printing
        case .paused:
            state.activity = .paused
            lastNote = "Paused. The nozzle is parked clear of the print and both heaters are still on, so "
                     + "it can carry on where it left off. Do not move the printer by hand."
        case .finished:
            state.activity = .connected
            log.append(TrafficEntry(direction: .info, text: "Print finished."))
        case .cancelled:
            state.activity = .connected
            lastNote = "The print was stopped. The nozzle was lifted clear and parked, both heaters are "
                     + "off and the motors are released."
        case .failed(let reason):
            // The link may or may not still be up; the link state decides that, not us.
            if state.activity.isJobActive { state.activity = .connected }
            lastError = "The print stopped: \(reason)"
        }

        if phase.isTerminal { sleepBlocker.end() }
    }

    /// True while the Mac is being held awake for a print.
    var isPreventingSleep: Bool { sleepBlocker.isActive }

    // MARK: - Movement

    /// True while an operation started here is still running.
    var isBusyWithOperation: Bool { operation != nil }

    /// Homes the given axes, or all of them when `axes` is empty.
    ///
    /// `G28` does not acknowledge until homing has physically finished, so by the time
    /// this returns the axes really are at their endstops.
    func home(_ axes: Set<PrinterAxis> = []) async {
        if let reason = state.homingBlockedReason() { lastError = reason; return }

        let requested = axes.isEmpty ? Set(PrinterAxis.allCases) : axes
        let named = PrinterAxis.allCases.filter(requested.contains).map(\.rawValue)
        let label = requested.count == PrinterAxis.allCases.count
            ? "Homing…"
            : "Homing \(named.joined(separator: " and "))…"

        await withOperation(label) {
            guard await self.send(MovePlanner.home(requested)) else { return }
            self.state.homedAxes.formUnion(requested)
            // Where "home" actually is depends on the machine and the firmware's
            // offsets, so ask rather than assume it is 0, 0, 0.
            await self.send(MovePlan(commands: ["M114"]))
        }
    }

    /// Moves one axis by a relative amount.
    func jog(axis: PrinterAxis, millimetres: Double) async {
        if let reason = state.movementBlockedReason() { lastError = reason; return }

        switch MovePlanner.jog(axis: axis, millimetres: millimetres, from: state.position, profile: profile) {
        case .refused(let reason):
            lastNote = reason
        case .go(let plan):
            lastNote = plan.note
            await withOperation("Moving \(axis.rawValue)…") {
                guard await self.send(plan) else { return }
                // `M400` only acknowledges once the queued moves have actually run, so
                // the position read after it is where the nozzle *is*, not where it is
                // heading. It gets Marlin's long timeout automatically.
                await self.send(MovePlan(commands: ["M400", "M114"]))
            }
        }
    }

    /// Moves X and then Y to a point 30 mm inside the selected bed corner.
    /// Z is intentionally untouched: this shortcut only replaces repeated X/Y jogging.
    func moveToBedLevelCorner(_ corner: BedLevelCorner) async {
        if let reason = state.movementBlockedReason() { lastError = reason; return }

        switch MovePlanner.moveToBedLevelCorner(corner, from: state.position, profile: profile) {
        case .refused(let reason):
            lastNote = reason
        case .go(let plan):
            await withOperation("Moving to \(corner.displayName)…") {
                guard await self.send(plan) else { return }
                self.lastNote = "At the \(corner.displayName) levelling point. Z was not moved."
            }
        }
    }

    /// Releases the steppers so the axes can be pushed by hand.
    func disableMotors() async {
        guard state.activity.isConnected else { lastError = "Connect to the printer first."; return }
        if state.activity.isJobActive { lastError = "The printer is in the middle of a job."; return }

        await withOperation("Releasing the motors…") {
            guard await self.send(MovePlanner.disableMotors()) else { return }
            // Nothing is holding the axes now, so any of them may be moved by hand. The
            // firmware's position becomes a guess, and so does ours.
            self.state.homedAxes = []
            self.state.position = nil
            self.lastNote = "The motors are off, so the axes can be moved by hand. That also means the "
                          + "printer no longer knows where they are — home it again before using the "
                          + "movement buttons."
        }
    }

    /// Asks the printer where it is (`M114`).
    func readPosition() async {
        await withOperation("Reading the position…") {
            await self.send(MovePlan(commands: ["M114"]))
        }
    }

    // MARK: - Extruder

    /// Pushes filament out (positive) or pulls it back (negative).
    func extrude(millimetres: Double) async {
        if let reason = state.extrusionBlockedReason(profile: profile) { lastError = reason; return }

        switch MovePlanner.extrude(millimetres: millimetres, profile: profile) {
        case .refused(let reason):
            lastNote = reason
        case .go(let plan):
            let verb = millimetres > 0 ? "Extruding" : "Retracting"
            let amount = MovePlanner.format(abs(millimetres))
            await withOperation("\(verb) \(amount) mm…") {
                guard await self.send(plan) else { return }
                // Filament moves slowly; wait for it so the button stops looking busy at
                // the moment the movement actually stops.
                await self.send(MovePlan(commands: ["M400"]))
            }
        }
    }

    // MARK: - Heaters

    func setTemperature(_ heater: Heater, celsius: Double) async {
        guard state.activity.isConnected else { lastError = "Connect to the printer first."; return }

        switch MovePlanner.setTemperature(heater, celsius: celsius, profile: profile) {
        case .refused(let reason):
            lastError = reason
        case .go(let plan):
            let name = heater.displayName.lowercased()
            let label = celsius > 0
                ? "Setting the \(name) to \(MovePlanner.format(celsius)) °C…"
                : "Turning the \(name) off…"
            await withOperation(label) {
                guard await self.send(plan) else { return }
                await self.refreshTemperatures()
            }
        }
    }

    func preheat(_ preset: PreheatPreset) async {
        guard state.activity.isConnected else { lastError = "Connect to the printer first."; return }

        let nozzle = MovePlanner.setTemperature(.hotend, celsius: preset.hotend, profile: profile)
        let bed = MovePlanner.setTemperature(.bed, celsius: preset.bed, profile: profile)
        if let refusal = nozzle.refusal ?? bed.refusal { lastError = refusal; return }

        let commands = (nozzle.plan?.commands ?? []) + (bed.plan?.commands ?? [])
        await withOperation("Heating up for \(preset.name)…") {
            guard await self.send(MovePlan(commands: commands)) else { return }
            await self.refreshTemperatures()
        }
    }

    func turnHeatersOff() async {
        guard state.activity.isConnected else { lastError = "Connect to the printer first."; return }
        await withOperation("Turning the heaters off…") {
            guard await self.send(MovePlanner.heatersOff()) else { return }
            await self.refreshTemperatures()
        }
    }

    /// Asks for a temperature reading now rather than waiting for the next scheduled
    /// one, so a new target appears on screen immediately after the button press.
    private func refreshTemperatures() async {
        await send(MovePlan(commands: ["M105"]))
    }

    // MARK: - Running a plan

    /// Claims the single operation slot for the duration of `body`.
    ///
    /// One user-initiated operation at a time: two overlapping jogs would interleave
    /// their `G91`/`G90` wrappers, and the second could execute in the wrong coordinate
    /// mode — an absolute move to X10 where a 10 mm nudge was intended.
    private func withOperation(_ label: String, _ body: () async -> Void) async {
        guard operation == nil else { return }
        operation = label
        defer { operation = nil }
        await body()
    }

    /// Sends a plan's commands in order, one at a time.
    ///
    /// Returns false if anything went wrong, so callers do not update state on a command
    /// that never completed — believing a `G28` homed the printer when its `ok` never
    /// arrived is exactly the kind of lie that ends with a nozzle in the bed.
    @discardableResult
    private func send(_ plan: MovePlan) async -> Bool {
        guard let connection else {
            lastError = "Not connected."
            return false
        }
        do {
            for command in plan.commands {
                try await connection.send(command, priority: .high)
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Display helpers

    /// "Ender-5 Pro • Connected" for the header.
    var headerTitle: String {
        let machine = state.firmware?.machineType ?? profile.name
        return "\(machine) • \(state.activity.label)"
    }

    var firmwareSummary: String? {
        guard let firmware = state.firmware else { return nil }
        var parts: [String] = [firmware.shortDescription]
        if let count = firmware.extruderCount { parts.append("\(count) extruder\(count == 1 ? "" : "s")") }
        return parts.joined(separator: " • ")
    }
}
