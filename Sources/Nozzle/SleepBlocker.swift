import Foundation

/// Keeps the Mac awake for the length of a print.
///
/// A print is a serial conversation: if the Mac sleeps, the USB port stops being
/// serviced, the printer runs out of buffered moves and stops mid-part with a hot nozzle
/// resting on it. Nothing in Nozzle can recover from that, so the answer is to not let
/// it happen.
///
/// `ProcessInfo.beginActivity` is the right API rather than an IOKit assertion: it is
/// scoped to a token, released automatically if this object goes away, and it tells the
/// system *why* — which is what shows up if the user ever asks what is keeping the Mac
/// awake.
///
/// What it cannot do: keep a laptop awake with the lid shut. macOS sleeps on lid close
/// regardless of any assertion an app holds, so the UI says so rather than letting the
/// user find out during a two-hour print.
@MainActor
final class SleepBlocker {

    private var token: (any NSObjectProtocol)?

    /// True while sleep is being held off.
    var isActive: Bool { token != nil }

    func begin(reason: String) {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: reason
        )
    }

    func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}
