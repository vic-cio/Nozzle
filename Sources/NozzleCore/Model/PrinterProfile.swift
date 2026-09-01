import Foundation

/// The machine's physical limits and Nozzle's connection preferences.
///
/// Every value is editable. These are *starting points* for a stock Ender-5 Pro, not
/// assertions about your machine: a second-hand printer may have a different hotend,
/// a modified bed, or reflashed firmware. Where Marlin can tell us the truth (via
/// `M115` capabilities), the firmware wins over anything written here.
public struct PrinterProfile: Codable, Equatable, Sendable {

    public var name: String

    // Build volume, in millimetres.
    public var maxX: Double
    public var maxY: Double
    public var maxZ: Double
    /// Some machines can move to slightly negative coordinates. Stock Ender-5 Pro cannot.
    public var minX: Double
    public var minY: Double
    public var minZ: Double

    public var nozzleDiameter: Double
    public var filamentDiameter: Double

    // Safety limits used to sanity-check anything the user or a G-code file asks for.
    public var maxHotendTemperature: Double
    public var maxBedTemperature: Double
    /// Marlin's own cold-extrusion threshold is 170 °C by default. We refuse below this
    /// too, so the user gets an explanation instead of a silent rejection from firmware.
    public var minimumExtrusionTemperature: Double

    // Connection.
    public var baudRate: Int
    public var preferredPortPath: String?

    // Protocol tuning. Conservative defaults; see `MarlinConfiguration`.
    public var useLineNumbersAndChecksums: Bool
    public var maxInFlightCommands: Int
    public var temperaturePollInterval: TimeInterval

    // Jogging speeds, in millimetres per minute — the unit Marlin's `F` word uses.
    // Well below the machine's maximum feedrates on purpose: a jog is something the
    // user is watching, and a slower move is easier to stop being a mistake.
    public var jogFeedrateXY: Double
    /// The Z axis is a leadscrew and is far slower than X or Y.
    public var jogFeedrateZ: Double
    /// Filament moves at roughly the speed it would during a print.
    public var extrudeFeedrate: Double

    // Convenience presets.
    public var plaNozzleTemperature: Double
    public var plaBedTemperature: Double

    // Where the nozzle goes when a print is paused or stopped.
    //
    // Not a corner: homing an Ender-5 drives X and Y into their endstops, and parking
    // hard against them every pause is needless wear. 10 mm in from each is clear of
    // the endstops and, on a bed this size, clear of anything centred on it — but a
    // print placed at the very front-left could reach it, which is why it is editable.
    public var parkX: Double
    public var parkY: Double
    /// How far the nozzle lifts off the part before parking. Enough to clear the
    /// printed height at the pause point, and clamped to the build volume.
    public var pauseZLift: Double
    /// Filament pulled back before parking, and pushed back on resume.
    ///
    /// A hot nozzle sitting still oozes, which leaves a void in the wall when printing
    /// resumes. The two amounts are deliberately equal so the extruder's absolute
    /// position is where the file expects it when the stream carries on.
    public var pauseRetract: Double

    public init(
        name: String,
        maxX: Double, maxY: Double, maxZ: Double,
        minX: Double = 0, minY: Double = 0, minZ: Double = 0,
        nozzleDiameter: Double = 0.4,
        filamentDiameter: Double = 1.75,
        maxHotendTemperature: Double = 260,
        maxBedTemperature: Double = 110,
        minimumExtrusionTemperature: Double = 170,
        baudRate: Int = BaudRate.marlinDefault,
        preferredPortPath: String? = nil,
        useLineNumbersAndChecksums: Bool = true,
        maxInFlightCommands: Int = 1,
        temperaturePollInterval: TimeInterval = 2,
        jogFeedrateXY: Double = 3000,
        jogFeedrateZ: Double = 600,
        extrudeFeedrate: Double = 300,
        plaNozzleTemperature: Double = 210,
        plaBedTemperature: Double = 60,
        parkX: Double = 10,
        parkY: Double = 10,
        pauseZLift: Double = 10,
        pauseRetract: Double = 5
    ) {
        self.name = name
        self.maxX = maxX; self.maxY = maxY; self.maxZ = maxZ
        self.minX = minX; self.minY = minY; self.minZ = minZ
        self.nozzleDiameter = nozzleDiameter
        self.filamentDiameter = filamentDiameter
        self.maxHotendTemperature = maxHotendTemperature
        self.maxBedTemperature = maxBedTemperature
        self.minimumExtrusionTemperature = minimumExtrusionTemperature
        self.baudRate = baudRate
        self.preferredPortPath = preferredPortPath
        self.useLineNumbersAndChecksums = useLineNumbersAndChecksums
        self.maxInFlightCommands = maxInFlightCommands
        self.temperaturePollInterval = temperaturePollInterval
        self.jogFeedrateXY = jogFeedrateXY
        self.jogFeedrateZ = jogFeedrateZ
        self.extrudeFeedrate = extrudeFeedrate
        self.plaNozzleTemperature = plaNozzleTemperature
        self.plaBedTemperature = plaBedTemperature
        self.parkX = parkX
        self.parkY = parkY
        self.pauseZLift = pauseZLift
        self.pauseRetract = pauseRetract
    }

    /// Stock Creality Ender-5 Pro (2019/2020), Marlin, 115200 baud.
    public static let ender5Pro = PrinterProfile(
        name: "Ender-5 Pro",
        maxX: 220, maxY: 220, maxZ: 300
    )

    /// Decodes tolerantly: any key the file does not have falls back to the default.
    ///
    /// The profile is a JSON file the user is invited to edit, and it outlives the
    /// version of Nozzle that wrote it. Refusing to decode because a newer field is
    /// missing would silently throw away the port and the build volume they had set.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = PrinterProfile.ender5Pro

        func value<T: Decodable>(_ key: CodingKeys, _ default: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? `default`
        }

        self.init(
            name: try value(.name, fallback.name),
            maxX: try value(.maxX, fallback.maxX),
            maxY: try value(.maxY, fallback.maxY),
            maxZ: try value(.maxZ, fallback.maxZ),
            minX: try value(.minX, fallback.minX),
            minY: try value(.minY, fallback.minY),
            minZ: try value(.minZ, fallback.minZ),
            nozzleDiameter: try value(.nozzleDiameter, fallback.nozzleDiameter),
            filamentDiameter: try value(.filamentDiameter, fallback.filamentDiameter),
            maxHotendTemperature: try value(.maxHotendTemperature, fallback.maxHotendTemperature),
            maxBedTemperature: try value(.maxBedTemperature, fallback.maxBedTemperature),
            minimumExtrusionTemperature: try value(.minimumExtrusionTemperature, fallback.minimumExtrusionTemperature),
            baudRate: try value(.baudRate, fallback.baudRate),
            preferredPortPath: try container.decodeIfPresent(String.self, forKey: .preferredPortPath),
            useLineNumbersAndChecksums: try value(.useLineNumbersAndChecksums, fallback.useLineNumbersAndChecksums),
            maxInFlightCommands: try value(.maxInFlightCommands, fallback.maxInFlightCommands),
            temperaturePollInterval: try value(.temperaturePollInterval, fallback.temperaturePollInterval),
            jogFeedrateXY: try value(.jogFeedrateXY, fallback.jogFeedrateXY),
            jogFeedrateZ: try value(.jogFeedrateZ, fallback.jogFeedrateZ),
            extrudeFeedrate: try value(.extrudeFeedrate, fallback.extrudeFeedrate),
            plaNozzleTemperature: try value(.plaNozzleTemperature, fallback.plaNozzleTemperature),
            plaBedTemperature: try value(.plaBedTemperature, fallback.plaBedTemperature),
            parkX: try value(.parkX, fallback.parkX),
            parkY: try value(.parkY, fallback.parkY),
            pauseZLift: try value(.pauseZLift, fallback.pauseZLift),
            pauseRetract: try value(.pauseRetract, fallback.pauseRetract)
        )
    }

    public var marlinConfiguration: MarlinConfiguration {
        var configuration = MarlinConfiguration()
        configuration.useLineNumbersAndChecksums = useLineNumbersAndChecksums
        configuration.maxInFlightCommands = maxInFlightCommands
        configuration.temperaturePollInterval = temperaturePollInterval
        return configuration
    }

    /// Whether a target coordinate is inside the configured build volume.
    public func isWithinBounds(x: Double?, y: Double?, z: Double?) -> Bool {
        if let x, x < minX || x > maxX { return false }
        if let y, y < minY || y > maxY { return false }
        if let z, z < minZ || z > maxZ { return false }
        return true
    }
}

/// Loads and saves the profile as JSON in Application Support.
///
/// Plain JSON rather than UserDefaults so it is easy to inspect, back up, or fix by
/// hand if a bad value ever makes the app misbehave.
public struct PrinterProfileStore: Sendable {

    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = base.appendingPathComponent("Nozzle/printer-profile.json")
        }
    }

    public func load() -> PrinterProfile {
        guard let data = try? Data(contentsOf: fileURL),
              let profile = try? JSONDecoder().decode(PrinterProfile.self, from: data)
        else { return .ender5Pro }
        return profile
    }

    public func save(_ profile: PrinterProfile) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profile).write(to: fileURL, options: .atomic)
        } catch {
            // Losing a preference is not worth interrupting a print for.
            NSLog("Nozzle: could not save printer profile: \(error.localizedDescription)")
        }
    }
}
