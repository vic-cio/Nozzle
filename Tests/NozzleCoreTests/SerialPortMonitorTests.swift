import Testing
import Foundation
@testable import NozzleCore

/// Watching for devices being plugged in.
///
/// What these tests can prove is that the watch is armed and that tearing it down is
/// safe. What they cannot prove is that macOS delivers the callback — that needs a
/// device to physically appear, and is recorded in `HARDWARE-TESTS.md`.
@Suite("Serial port monitor")
@MainActor
struct SerialPortMonitorTests {

    @Test("Starting arms both the attach and the detach notification")
    func startArmsBothNotifications() {
        let monitor = SerialPortMonitor()
        defer { monitor.stop() }

        monitor.start { }

        #expect(monitor.armedNotificationCount == 2)
    }

    @Test("Starting twice does not leave the first watch behind")
    func startingTwiceReplacesTheWatch() {
        let monitor = SerialPortMonitor()
        defer { monitor.stop() }

        monitor.start { }
        monitor.start { }

        #expect(monitor.armedNotificationCount == 2)
    }

    @Test("Stopping is idempotent")
    func stopIsIdempotent() {
        let monitor = SerialPortMonitor()

        monitor.start { }
        monitor.stop()
        monitor.stop()

        #expect(monitor.armedNotificationCount == 0)
    }

    @Test("Stopping without starting is harmless")
    func stopWithoutStart() {
        let monitor = SerialPortMonitor()
        monitor.stop()
        #expect(monitor.armedNotificationCount == 0)
    }

    /// The list itself must keep coming from `/dev`: the monitor says *when*, never *what*.
    @Test("Discovery still answers while a monitor is running")
    func discoveryUnaffectedByMonitoring() {
        let monitor = SerialPortMonitor()
        defer { monitor.stop() }
        monitor.start { }

        // No assertion about which ports exist — this machine may have none. The point
        // is that scanning still works and does not trip over the armed notification.
        _ = SerialPortDiscovery.availablePorts()
    }
}
