import Foundation

/// Classifies hand-typed console commands so the risky ones need a deliberate second step.
///
/// This is a guard rail for typos, not a security boundary — the Console must stay able
/// to send anything, because being able to send anything is the point of a console.
public enum CommandSafety {

    public enum Risk: Sendable, Equatable {
        case ordinary
        /// Worth a confirmation sheet explaining what will happen.
        case dangerous(reason: String)

        public var requiresConfirmation: Bool {
            if case .dangerous = self { return true }
            return false
        }
    }

    /// Commands that can damage hardware, destroy calibration, or halt the machine.
    private static let table: [(prefix: String, reason: String)] = [
        ("M112", "Emergency stop. Marlin halts and stays halted — the printer must be power-cycled before it will do anything else."),
        ("M999", "Clears a halt state. Only do this once you know why the printer halted; the fault may still be present."),
        ("M502", "Resets all firmware settings to the factory defaults compiled into the firmware. Your steps/mm, PID and Z offset will be replaced."),
        ("M500", "Writes the current settings to EEPROM permanently, overwriting what is stored now."),
        ("M851", "Changes the Z probe offset. A wrong value here drives the nozzle into the bed."),
        ("M206", "Changes the home offset. A wrong value moves every subsequent print, including into the bed."),
        ("M303", "PID autotune. Runs the heater to the target temperature repeatedly for several minutes — do not leave it unattended."),
        ("M301", "Overwrites the hotend PID tuning."),
        ("M304", "Overwrites the bed PID tuning."),
        ("M92",  "Changes steps per millimetre. Wrong values make every axis move the wrong distance."),
        ("M201", "Changes maximum acceleration limits."),
        ("M203", "Changes maximum feedrates."),
        ("M211", "Enables or disables software endstops — with these off, nothing stops a move from crashing into the frame."),
        ("M290", "Applies a babystep Z offset while printing."),
        ("M562", "Resets a fault condition."),
        ("G29",  "Runs bed levelling. Make sure the bed is clear and the nozzle is clean first."),
        ("G30",  "Single-point probe. The nozzle will move down towards the bed."),
        ("M280", "Drives a servo directly — on BLTouch clones this can deploy or damage the probe pin."),
    ]

    public static func assess(_ command: String) -> Risk {
        let normalised = MarlinConnection.sanitise(command).uppercased()
        guard !normalised.isEmpty else { return .ordinary }

        // Match on the whole word so M11 does not trigger M112's warning, and M1120
        // (were it to exist) does not either.
        for entry in table where matchesCode(normalised, entry.prefix) {
            return .dangerous(reason: entry.reason)
        }
        return .ordinary
    }

    private static func matchesCode(_ command: String, _ code: String) -> Bool {
        guard command.hasPrefix(code) else { return false }
        guard command.count > code.count else { return true }
        let next = command[command.index(command.startIndex, offsetBy: code.count)]
        return !next.isNumber
    }

    /// Marlin's real-time commands, which bypass the queue via the emergency parser.
    public static func isEmergency(_ command: String) -> Bool {
        let normalised = MarlinConnection.sanitise(command).uppercased()
        return ["M112", "M108", "M410", "M876"].contains { matchesCode(normalised, $0) }
    }
}
