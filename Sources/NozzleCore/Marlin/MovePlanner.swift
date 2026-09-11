import Foundation

/// One of the machine's three linear axes.
///
/// Named `PrinterAxis` rather than `Axis` because SwiftUI already has an `Axis`
/// (horizontal/vertical); shadowing it in every view file is a trap worth avoiding.
public enum PrinterAxis: String, CaseIterable, Sendable, Hashable, Codable, Identifiable {
    case x = "X"
    case y = "Y"
    case z = "Z"

    public var id: String { rawValue }
}

/// Which heater a command is aimed at.
public enum Heater: String, Sendable, Equatable, CaseIterable, Codable, Identifiable {
    case hotend
    case bed

    public var id: String { rawValue }

    /// The words the user sees. "Nozzle", not "hotend" or "E0".
    public var displayName: String {
        switch self {
        case .hotend: return "Nozzle"
        case .bed:    return "Bed"
        }
    }
}

/// A set of commands Nozzle is willing to send, plus anything the user should know
/// about how it differs from what they asked for.
public struct MovePlan: Equatable, Sendable {
    public let commands: [String]
    /// Non-nil when Nozzle changed the request — e.g. shortened a jog so it stops at
    /// the edge of the build volume. Shown to the user; never applied silently.
    public let note: String?

    public init(commands: [String], note: String? = nil) {
        self.commands = commands
        self.note = note
    }
}

/// The answer to "can I do this, and if so what do I send?".
///
/// Refusals carry a plain-English reason rather than a bare `nil`, because the UI's
/// job is to explain why a button did nothing — not to grey it out and stay silent.
public enum PlanResult: Equatable, Sendable {
    case refused(String)
    case go(MovePlan)

    public var plan: MovePlan? {
        if case .go(let plan) = self { return plan }
        return nil
    }

    public var refusal: String? {
        if case .refused(let reason) = self { return reason }
        return nil
    }
}

/// Turns an intent ("jog X by 10 mm", "heat the nozzle to 210") into G-code.
///
/// Pure functions over a profile and the last known position: no port, no actor, no
/// clock. Everything here can be checked with a string comparison in a test, which is
/// the point — this is the layer that decides how far the nozzle is allowed to move.
public enum MovePlanner {

    // MARK: - Homing

    /// `G28`, optionally for specific axes.
    ///
    /// An empty or complete selection becomes a bare `G28`, which is the canonical form
    /// and the one least likely to surprise a firmware fork.
    public static func home(_ axes: Set<PrinterAxis>) -> MovePlan {
        if axes.isEmpty || axes.count == PrinterAxis.allCases.count {
            return MovePlan(commands: ["G28"])
        }
        let letters = PrinterAxis.allCases.filter { axes.contains($0) }.map(\.rawValue)
        return MovePlan(commands: ["G28 \(letters.joined(separator: " "))"])
    }

    /// `M84` — release the stepper motors so the axes can be pushed by hand.
    public static func disableMotors() -> MovePlan {
        MovePlan(commands: ["M84"])
    }

    // MARK: - Manual bed levelling shortcuts

    /// Four points 30 mm inside the configured bed edges.
    ///
    /// On a bed narrower than 60 mm the inset is reduced to the midpoint, keeping every
    /// generated coordinate inside the configured build volume.
    public static func bedLevelPoints(profile: PrinterProfile) -> [BedLevelPoint] {
        let xInset = min(30, max(0, (profile.maxX - profile.minX) / 2))
        let yInset = min(30, max(0, (profile.maxY - profile.minY) / 2))
        let left = profile.minX + xInset
        let right = profile.maxX - xInset
        let front = profile.minY + yInset
        let rear = profile.maxY - yInset

        return [
            BedLevelPoint(corner: .frontLeft, x: left, y: front),
            BedLevelPoint(corner: .frontRight, x: right, y: front),
            BedLevelPoint(corner: .rearRight, x: right, y: rear),
            BedLevelPoint(corner: .rearLeft, x: left, y: rear),
        ]
    }

    /// Moves to a manual-levelling corner without changing Z.
    ///
    /// X deliberately moves before Y. This gets the nozzle 30 mm away from either
    /// X edge before it travels along Y, avoiding bed clips mounted halfway along Y at
    /// X=min or X=max. The user remains solely responsible for the current Z height.
    public static func moveToBedLevelCorner(
        _ corner: BedLevelCorner,
        from position: PositionReport?,
        profile: PrinterProfile
    ) -> PlanResult {
        guard profile.maxX >= profile.minX, profile.maxY >= profile.minY else {
            return .refused("The configured X/Y build volume is invalid, so Nozzle cannot calculate a safe corner.")
        }
        guard position?.x != nil, position?.y != nil else {
            return .refused("Nozzle does not know the current X/Y position. Home the printer first.")
        }
        guard let point = bedLevelPoints(profile: profile).first(where: { $0.corner == corner }),
              profile.isWithinBounds(x: point.x, y: point.y, z: nil)
        else {
            return .refused("The levelling point is outside the configured build volume.")
        }

        return .go(MovePlan(commands: [
            "G90",
            "G0 X\(format(point.x)) F\(format(profile.jogFeedrateXY))",
            "G0 Y\(format(point.y)) F\(format(profile.jogFeedrateXY))",
            "M400",
            "M114",
        ]))
    }

    // MARK: - Jogging

    /// Plans a relative move of one axis.
    ///
    /// Two deliberate choices:
    ///
    /// - **Relative (`G91`), not absolute.** A relative move is correct even if Nozzle's
    ///   idea of the position has drifted — say the user moved the printer from its own
    ///   screen. An absolute move computed from a stale position would go somewhere
    ///   nobody asked for.
    /// - **Bounds are still checked against the last known position, and the move is
    ///   shortened rather than refused outright** when it would leave the build volume.
    ///   Marlin's software endstops are the real backstop; this exists so the user is
    ///   told what happened instead of watching the axis stop early for no visible reason.
    public static func jog(
        axis: PrinterAxis,
        millimetres: Double,
        from position: PositionReport?,
        profile: PrinterProfile
    ) -> PlanResult {
        guard millimetres != 0 else {
            return .refused("A zero-millimetre move would not do anything.")
        }
        guard let current = position?.value(for: axis) else {
            return .refused("Nozzle does not know where the \(axis.rawValue) axis is yet. "
                          + "Home the printer, or read the position, first.")
        }

        let lower = profile.minimum(for: axis)
        let upper = profile.maximum(for: axis)
        let requested = current + millimetres
        let target = min(max(requested, lower), upper)
        let delta = target - current

        // 1 µm: below the resolution of any of these axes, so a "move" this small is
        // really "already there".
        let epsilon = 0.001

        guard abs(delta) >= epsilon else {
            let limit = millimetres > 0 ? upper : lower
            return .refused("The \(axis.rawValue) axis is already at \(format(current)) mm, which is its "
                          + "limit of \(format(limit)) mm in that direction. Moving further would drive it "
                          + "into the frame.")
        }

        var note: String?
        if abs(target - requested) >= epsilon {
            note = "Moved \(format(delta)) mm instead of \(format(millimetres)) mm: "
                 + "\(format(requested)) mm is outside the build volume, so the move stops at "
                 + "\(format(target)) mm."
        }

        let feedrate = axis == .z ? profile.jogFeedrateZ : profile.jogFeedrateXY
        return .go(MovePlan(
            commands: [
                "G91",
                "G0 \(axis.rawValue)\(format(delta)) F\(format(feedrate))",
                "G90",
            ],
            note: note
        ))
    }

    // MARK: - Extrusion

    /// The most filament one press of a button may push or pull.
    ///
    /// The UI only offers preset amounts, so this is a guard against a future caller
    /// passing something absurd — not a limit the user will ever meet.
    public static let maximumExtrusionPerCommand: Double = 200

    /// Plans an extrude (positive) or retract (negative).
    ///
    /// Whether the nozzle is hot enough is *not* decided here — that is
    /// `PrinterState.extrusionBlockedReason(profile:)`, because it depends on live
    /// temperature rather than on the request. This function only builds the G-code.
    public static func extrude(millimetres: Double, profile: PrinterProfile) -> PlanResult {
        guard millimetres != 0 else {
            return .refused("A zero-millimetre extrusion would not do anything.")
        }
        guard abs(millimetres) <= maximumExtrusionPerCommand else {
            return .refused("\(format(abs(millimetres))) mm is more filament than Nozzle will move in one "
                          + "go (the limit is \(format(maximumExtrusionPerCommand)) mm). Press the button "
                          + "again instead.")
        }

        // M83 makes the E value a distance rather than a destination; M82 puts it back
        // to absolute, which is how stock Marlin starts up and what a Cura file's own
        // header expects to find when a print begins.
        return .go(MovePlan(commands: [
            "M83",
            "G1 E\(format(millimetres)) F\(format(profile.extrudeFeedrate))",
            "M82",
        ]))
    }

    // MARK: - Heaters

    /// Plans a heater target change.
    ///
    /// Uses `M104`/`M140` (set and carry on), never `M109`/`M190` (set and block until
    /// reached). A blocking heat-up holds the command queue for minutes, during which
    /// nothing else — jogging, reading the position, turning the heater back off —
    /// could get through. Printing uses the blocking forms where a file asks for them;
    /// interactive heating must not.
    public static func setTemperature(_ heater: Heater, celsius: Double, profile: PrinterProfile) -> PlanResult {
        guard celsius >= 0 else {
            return .refused("A target below 0 °C is not something the printer can do.")
        }
        let limit = heater == .hotend ? profile.maxHotendTemperature : profile.maxBedTemperature
        guard celsius <= limit else {
            return .refused("\(format(celsius)) °C is above the \(format(limit)) °C limit set for the "
                          + "\(heater.displayName.lowercased()) in this printer's profile. Raise the limit "
                          + "in the profile if the hardware really can take it.")
        }

        let code = heater == .hotend ? "M104" : "M140"
        return .go(MovePlan(commands: ["\(code) S\(format(celsius.rounded()))"]))
    }

    /// Both heaters off. Fans and motors are left alone.
    public static func heatersOff() -> MovePlan {
        MovePlan(commands: ["M104 S0", "M140 S0"])
    }

    // MARK: - Pausing a print

    /// Everything Nozzle sends to get the nozzle off the part and out of the way.
    ///
    /// Three things happen, in this order, and the order is the point:
    ///
    /// 1. **Retract.** A stationary hot nozzle drools. Pulling the filament back stops
    ///    the ooze that would otherwise leave a void in the wall when printing resumes.
    /// 2. **Lift.** Relative, so it works from wherever the layer had got to, and
    ///    clamped so a print near the top of the build volume cannot drive Z into its
    ///    limit.
    /// 3. **Park.** Absolute, to a fixed spot from the profile, so the nozzle is not
    ///    left radiating heat into the top of the part for the length of the pause.
    ///
    /// Every modal setting the plan touches — `G90`/`G91`, `M82`/`M83` — is put back to
    /// what `modal` says the file was using. Nothing about the file's own state is
    /// assumed; see `GCodeModalState` for why that matters.
    ///
    /// Refused outright if the position is unknown, because a pause we cannot reverse is
    /// worse than no pause at all: the user would press Resume and the nozzle would go
    /// somewhere nobody chose.
    public static func pausePark(
        from position: PositionReport?,
        modal: GCodeModalState,
        profile: PrinterProfile
    ) -> PlanResult {
        guard let position, position.x != nil, position.y != nil, let z = position.z else {
            return .refused("Nozzle could not read where the nozzle is, so it cannot promise to put it "
                          + "back. Stopping the print is still safe; pausing is not.")
        }

        var commands: [String] = []
        var note: String?

        if profile.pauseRetract > 0 {
            commands += [
                "M83",
                "G1 E-\(format(profile.pauseRetract)) F\(format(profile.extrudeFeedrate))",
            ]
        }

        // Clamp: `maxZ` is the top of the build volume, and a tall print may already be
        // most of the way there.
        let lift = min(profile.pauseZLift, max(0, profile.maxZ - z))
        if lift > 0.001 {
            commands += [
                "G91",
                "G0 Z\(format(lift)) F\(format(profile.jogFeedrateZ))",
            ]
        } else {
            note = "The print is already near the top of the build volume, so the nozzle was parked "
                 + "without lifting clear of it first."
        }

        let parkX = min(max(profile.parkX, profile.minX), profile.maxX)
        let parkY = min(max(profile.parkY, profile.minY), profile.maxY)
        commands += [
            "G90",
            "G0 X\(format(parkX)) Y\(format(parkY)) F\(format(profile.jogFeedrateXY))",
        ]

        commands += restoringModes(modal)
        return .go(MovePlan(commands: commands, note: note))
    }

    /// The mirror image: back to where the file left off, then carry on.
    ///
    /// X and Y first at the parked height, *then* Z down, *then* the prime. Going back
    /// down before crossing the bed would drag the nozzle across the part, and priming
    /// before the nozzle is back over its own extrusion leaves a blob wherever it was.
    /// This is the order Marlin's own pause/resume uses.
    ///
    /// The last line restores the feedrate the file was printing at. Without it, the
    /// remainder of the layer would run at whatever speed the park moves used, which
    /// shows up in the part as a band.
    public static func resumeReturn(
        to position: PositionReport?,
        modal: GCodeModalState,
        profile: PrinterProfile
    ) -> PlanResult {
        guard let position, let x = position.x, let y = position.y, let z = position.z else {
            return .refused("Nozzle does not have a recorded position to return to.")
        }

        var commands = [
            "G90",
            "G0 X\(format(x)) Y\(format(y)) F\(format(profile.jogFeedrateXY))",
            "G0 Z\(format(z)) F\(format(profile.jogFeedrateZ))",
        ]

        if profile.pauseRetract > 0 {
            commands += [
                "M83",
                "G1 E\(format(profile.pauseRetract)) F\(format(profile.extrudeFeedrate))",
            ]
        }

        commands += restoringModes(modal)
        if let feedrate = modal.feedrate, feedrate > 0 {
            commands.append("G1 F\(format(feedrate))")
        }
        return .go(MovePlan(commands: commands))
    }

    /// Puts `G90`/`G91` and `M82`/`M83` back to what the file was using.
    ///
    /// Sent unconditionally rather than only when they differ from Marlin's boot
    /// defaults: the cost is two lines, and the alternative is reasoning about which of
    /// two independent flags a park sequence happened to leave in which state.
    private static func restoringModes(_ modal: GCodeModalState) -> [String] {
        [
            modal.relativeMoves ? "G91" : "G90",
            modal.relativeExtrusion ? "M83" : "M82",
        ]
    }

    // MARK: - Stopping a print

    /// Leaves the machine safe after a print is abandoned.
    ///
    /// Ordered so that each step is still possible when it runs: retract and lift while
    /// the filament is soft enough to separate from the part, park away from it, and
    /// only then turn the heat off and release the steppers.
    ///
    /// - Parameter alreadyParked: true when the print was paused, so the retract, lift
    ///   and park have already happened and repeating them would only lift twice.
    ///
    /// Note what is deliberately *not* here: `M112`. On firmware without
    /// `Cap:EMERGENCY_PARSER` it is not an emergency stop at all — it waits its turn
    /// like any other command — and it then halts the board until it is power-cycled.
    /// For an abandoned print, that trades a tidy stop for a machine that needs
    /// rebooting. For a real emergency, the power switch is both faster and honest.
    public static func stop(profile: PrinterProfile, alreadyParked: Bool) -> MovePlan {
        var commands: [String] = []

        if !alreadyParked {
            if profile.pauseRetract > 0 {
                commands += [
                    "M83",
                    "G1 E-\(format(profile.pauseRetract)) F\(format(profile.extrudeFeedrate))",
                    "M82",
                ]
            }
            // No clamp on the lift here, unlike `pausePark`: stopping does not read the
            // position first — the whole point is to be quick — so Marlin's software
            // endstops are the backstop. They are trustworthy at this moment because a
            // print has necessarily homed the machine.
            let parkX = min(max(profile.parkX, profile.minX), profile.maxX)
            let parkY = min(max(profile.parkY, profile.minY), profile.maxY)
            commands += [
                "G91",
                "G0 Z\(format(profile.pauseZLift)) F\(format(profile.jogFeedrateZ))",
                "G90",
                "G0 X\(format(parkX)) Y\(format(parkY)) F\(format(profile.jogFeedrateXY))",
            ]
        }

        // Fans are left running: the hotend has thermal protection but no fan control
        // here, and a fan that keeps spinning while things cool harms nothing.
        commands += ["M104 S0", "M140 S0", "M84"]
        return MovePlan(commands: commands)
    }

    // MARK: - Formatting

    /// Marlin accepts plain decimals. Trailing zeros are stripped so the Console shows
    /// `G0 X10` rather than `G0 X10.000`.
    public static func format(_ value: Double) -> String {
        // -0.0 formats as "-0", which reads as a bug in the Console.
        let cleaned = value == 0 ? 0 : value
        if cleaned == cleaned.rounded(), abs(cleaned) < 1_000_000 {
            return String(format: "%.0f", cleaned)
        }
        var text = String(format: "%.3f", cleaned)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// A named nozzle + bed pairing for the Preheat buttons.
public struct PreheatPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let hotend: Double
    public let bed: Double
    /// One line explaining what the material is, in the user's terms.
    public let note: String

    public init(id: String, name: String, hotend: Double, bed: Double, note: String) {
        self.id = id
        self.name = name
        self.hotend = hotend
        self.bed = bed
        self.note = note
    }

    /// The presets offered on the Temperatures screen.
    ///
    /// PLA comes from the profile so it can be edited; the rest are ordinary starting
    /// points for the material, and every spool's label wins over any of them.
    public static func standard(for profile: PrinterProfile) -> [PreheatPreset] {
        [
            PreheatPreset(
                id: "pla",
                name: "PLA",
                hotend: profile.plaNozzleTemperature,
                bed: profile.plaBedTemperature,
                note: "The usual filament for this printer. Check the spool: most PLA wants 200–225 °C."
            ),
            PreheatPreset(
                id: "petg",
                name: "PETG",
                hotend: 240,
                bed: 80,
                note: "Tougher and more heat-resistant than PLA, and needs a hotter nozzle and bed."
            ),
        ]
    }
}

// MARK: - Small conveniences these plans need

public extension PositionReport {
    /// The reported coordinate for one axis, or `nil` if the printer did not say.
    func value(for axis: PrinterAxis) -> Double? {
        switch axis {
        case .x: return x
        case .y: return y
        case .z: return z
        }
    }
}

public extension PrinterProfile {
    func minimum(for axis: PrinterAxis) -> Double {
        switch axis {
        case .x: return minX
        case .y: return minY
        case .z: return minZ
        }
    }

    func maximum(for axis: PrinterAxis) -> Double {
        switch axis {
        case .x: return maxX
        case .y: return maxY
        case .z: return maxZ
        }
    }
}
