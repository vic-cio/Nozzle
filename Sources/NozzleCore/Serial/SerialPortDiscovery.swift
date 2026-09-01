import Foundation
import IOKit
import IOKit.serial

/// One serial device the user could connect to.
public struct SerialPortInfo: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// `/dev/cu.*` — "callout". Does not wait for carrier detect. The right
        /// choice for a 3D printer on macOS.
        case callout
        /// `/dev/tty.*` — "dial-in". Blocks on open until DCD is asserted, which
        /// for USB adapters can mean hanging forever.
        case dialin
    }

    public var id: String { path }
    public var path: String
    public var kind: Kind
    /// USB product string from IOKit when available, e.g. "USB2.0-Serial".
    public var productName: String?
    /// How likely this is to be the printer. Higher is better; used for auto-select.
    public var score: Int

    /// What to show in the port picker.
    public var displayName: String {
        let leaf = (path as NSString).lastPathComponent
        if let productName, !productName.isEmpty { return "\(productName) — \(leaf)" }
        return leaf
    }

    /// A plain-English hint, so a first-time user knows which entry to pick.
    public var hint: String? {
        switch score {
        case 100...: return "Most likely your printer"
        case 70..<100: return "A USB serial device — probably your printer"
        case 1..<70: return "A USB device"
        default: return "Probably not a printer"
        }
    }
}

public enum SerialPortDiscovery {

    /// All plausible serial ports, best candidate first.
    ///
    /// `/dev` is the source of truth (it cannot fail); IOKit is used only to add
    /// friendly product names, and any IOKit failure degrades silently.
    public static func availablePorts(includeDialin: Bool = false) -> [SerialPortInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let products = productNamesByCalloutPath()

        var ports: [SerialPortInfo] = []
        for name in names {
            let kind: SerialPortInfo.Kind
            if name.hasPrefix("cu.") {
                kind = .callout
            } else if name.hasPrefix("tty.") {
                guard includeDialin else { continue }
                kind = .dialin
            } else {
                continue
            }

            let path = "/dev/" + name
            let score = candidateScore(for: name)
            guard score > Int.min else { continue }

            // Product names are registered against the callout path; reuse them for tty.*
            let calloutEquivalent = kind == .callout ? path : "/dev/cu." + name.dropFirst("tty.".count)

            ports.append(SerialPortInfo(
                path: path,
                kind: kind,
                productName: products[calloutEquivalent],
                // Prefer cu.* when both forms of the same device are listed.
                score: kind == .callout ? score : score - 5
            ))
        }

        return ports.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path
        }
    }

    /// The port we would connect to automatically, if any is obviously the printer.
    public static func bestGuess(from ports: [SerialPortInfo]) -> SerialPortInfo? {
        ports.first { $0.score >= 70 }
    }

    /// Ranks a `/dev` entry by how printer-like its name is.
    /// Returns `Int.min` for devices that should not appear at all.
    private static func candidateScore(for name: String) -> Int {
        let lower = name.lowercased()

        // Built-in macOS ports that are never a printer.
        let excluded = ["bluetooth", "debug-console", "wlan-debug", "airconsole"]
        if excluded.contains(where: { lower.contains($0) }) { return Int.min }

        if lower.contains("wchusbserial") { return 110 }  // CH340/CH341 — stock Creality boards
        if lower.contains("slab_usbtouart") { return 100 } // CP210x
        if lower.contains("usbserial") { return 95 }       // FTDI and generic
        if lower.contains("usbmodem") { return 75 }        // native USB (32-bit boards)
        return 10
    }

    // MARK: - IOKit enrichment (best-effort)

    /// Maps `/dev/cu.*` paths to their USB product string.
    private static func productNamesByCalloutPath() -> [String: String] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [:] }
        let dictionary = matching as NSMutableDictionary
        dictionary[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dictionary as CFDictionary, &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }

        var result: [String: String] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let callout = stringProperty(service, kIOCalloutDeviceKey) else { continue }
            // The product string lives on a USB ancestor, not the serial node itself.
            if let product = inheritedStringProperty(service, "USB Product Name")
                ?? inheritedStringProperty(service, "Product Name") {
                result[callout] = product
            }
        }
        return result
    }

    private static func stringProperty(_ service: io_object_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        return value.takeRetainedValue() as? String
    }

    private static func inheritedStringProperty(_ service: io_object_t, _ key: String) -> String? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let value = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options
        ) else { return nil }
        return value as? String
    }
}
