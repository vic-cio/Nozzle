import Foundation
import IOKit
import IOKit.serial

/// Tells the app when serial devices are attached or removed, so the port list can
/// stay honest without the user pressing Refresh.
///
/// IOKit is the only thing that knows the *moment* a USB device appears. The list
/// itself is still rebuilt from `/dev` by `SerialPortDiscovery` — this only says
/// *when* to rebuild it, which keeps one source of truth rather than two that can
/// disagree.
///
/// Deliberately says nothing about *which* device changed. Re-reading `/dev` costs a
/// directory listing, and a full rescan cannot end up out of step with reality the way
/// an incrementally maintained list can.
@MainActor
public final class SerialPortMonitor {

    private var notificationPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var onChange: (() -> Void)?
    private var settleTask: Task<Void, Never>?

    public init() {}

    /// How many notifications are armed: 2 when watching, 0 when stopped. Anything
    /// else means IOKit refused a registration and plug-in detection is degraded.
    var armedNotificationCount: Int { iterators.count }

    /// Starts watching. `onChange` runs on the main actor.
    ///
    /// If IOKit refuses to set the watch — which should not happen, but is not worth
    /// crashing over — the app simply behaves as it did before: the manual Refresh
    /// button still works.
    public func start(onChange: @escaping () -> Void) {
        stop()
        self.onChange = onChange

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        let context = Unmanaged.passUnretained(self).toOpaque()

        // Attach and detach are separate notifications, and each one consumes its own
        // matching dictionary, so build a fresh dictionary per registration.
        for notificationType in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { continue }
            let dictionary = matching as NSMutableDictionary
            dictionary[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(
                port,
                notificationType,
                dictionary as CFDictionary,
                { context, iterator in
                    guard let context else { return }
                    let monitor = Unmanaged<SerialPortMonitor>.fromOpaque(context)
                        .takeUnretainedValue()
                    // Callbacks are delivered on the main queue by
                    // IONotificationPortSetDispatchQueue above.
                    MainActor.assumeIsolated { monitor.devicesChanged(iterator) }
                },
                context,
                &iterator
            )
            guard result == KERN_SUCCESS else { continue }
            iterators.append(iterator)

            // Arming. A matching notification's iterator must be drained once before
            // IOKit will deliver anything further; the first pass lists the devices
            // already attached, which the caller has just scanned for itself.
            drain(iterator)
        }
    }

    public func stop() {
        settleTask?.cancel()
        settleTask = nil
        for iterator in iterators { IOObjectRelease(iterator) }
        iterators.removeAll()
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        notificationPort = nil
        onChange = nil
    }

    private func devicesChanged(_ iterator: io_iterator_t) {
        drain(iterator)
        onChange?()

        // The `/dev` node is created by the driver at about the same moment IOKit
        // publishes the service, and the two are not ordered with respect to each
        // other. One repeat scan shortly afterwards costs a directory listing and
        // removes any doubt about which of them won the race.
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }

    /// Consumes every object an iterator is holding. Required: an undrained iterator
    /// stops delivering notifications.
    private func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }
}
