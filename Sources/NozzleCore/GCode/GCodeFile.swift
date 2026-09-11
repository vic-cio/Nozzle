import Foundation

/// The volume a sliced file actually uses, from Cura's `;MINX:`/`;MAXX:` header.
public struct GCodeBounds: Codable, Equatable, Sendable {
    public var minX: Double?
    public var minY: Double?
    public var minZ: Double?
    public var maxX: Double?
    public var maxY: Double?
    public var maxZ: Double?

    public init() {}

    /// True once we know enough to check the file against a build volume.
    public var isUsable: Bool { maxX != nil && maxY != nil && maxZ != nil }

    /// "42 × 42 × 20 mm"
    public var sizeDescription: String? {
        guard let minX, let maxX, let minY, let maxY, let maxZ else { return nil }
        let depth = maxZ - (minZ ?? 0)
        return "\(MovePlanner.format(maxX - minX)) × \(MovePlanner.format(maxY - minY)) × "
             + "\(MovePlanner.format(depth)) mm"
    }
}

/// One layer, and where it sits in the file.
public struct GCodeLayer: Codable, Equatable, Sendable {
    /// Cura's own `;LAYER:` number, which starts at 0.
    public let number: Int
    public let firstLineIndex: Int
    /// Where this layer's timed work ends — its `;TIME_ELAPSED:` line where the slicer
    /// wrote one, otherwise the start of the next layer.
    ///
    /// Not simply "the next layer's first line": the end of the file is followed by a
    /// footer that cools the heaters and parks the machine, and counting that as part of
    /// the last layer leaves the progress bar short of the end.
    public var endLineIndex: Int
    /// Cumulative print time at the *end* of this layer, from `;TIME_ELAPSED:`.
    public var elapsedAtEnd: TimeInterval?

    public init(number: Int, firstLineIndex: Int, endLineIndex: Int, elapsedAtEnd: TimeInterval? = nil) {
        self.number = number
        self.firstLineIndex = firstLineIndex
        self.endLineIndex = endLineIndex
        self.elapsedAtEnd = elapsedAtEnd
    }
}

/// What the slicer told us, scraped from the comments it leaves in the file.
///
/// Every field is optional on purpose. A hand-written file, or one from a slicer that
/// is not Cura, has none of this — and that must degrade to "we do not know" rather
/// than to a confident wrong number.
public struct GCodeMetadata: Codable, Equatable, Sendable {
    public var flavor: String?
    public var generator: String?
    public var targetMachine: String?
    /// `;TIME:` — the slicer's estimate for the whole print.
    public var estimatedDuration: TimeInterval?
    public var layerHeight: Double?
    public var filamentUsedMetres: Double?
    public var declaredLayerCount: Int?
    public var bounds = GCodeBounds()

    /// The hottest target the file ever asks for, so it can be checked against the
    /// profile's limits before a single line is sent.
    public var maxHotendTarget: Double?
    public var maxBedTarget: Double?

    /// Whether the file homes itself. Cura's start G-code does; a fragment might not.
    public var homesItself = false

    public init() {}
}

public enum GCodeError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case empty
    case noCommands

    public var errorDescription: String? {
        switch self {
        case .unreadable(let why): return "That file could not be read: \(why)"
        case .empty:               return "That file is empty."
        case .noCommands:          return "That file has no G-code commands in it — only comments."
        }
    }
}

/// A loaded `.gcode` file, indexed so a print can be streamed from it and reported on.
///
/// Held in memory whole. A big calibration print is well under a megabyte, and the
/// alternative — streaming from disk while printing — trades a real risk (an I/O stall
/// starving the printer's buffer mid-layer) for memory nobody is short of.
public struct GCodeFile: Sendable, Equatable {

    public let name: String
    public let url: URL?
    /// Every line of the file, comments included, so the Console can show what was sent.
    public let lines: [String]
    /// Indices into `lines` that are real commands — not blank, not comment-only.
    public let commandLineIndices: [Int]
    public let layers: [GCodeLayer]
    public let metadata: GCodeMetadata

    public var commandCount: Int { commandLineIndices.count }
    public var layerCount: Int { metadata.declaredLayerCount ?? layers.count }

    // MARK: - Loading

    public static func load(contentsOf url: URL) throws -> GCodeFile {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Slicers occasionally emit a stray non-UTF-8 byte in a comment; that is no
            // reason to refuse a file whose commands are plain ASCII.
            guard let data = try? Data(contentsOf: url),
                  let lossy = String(data: data, encoding: .isoLatin1)
            else {
                throw GCodeError.unreadable(error.localizedDescription)
            }
            text = lossy
        }
        return try parse(text, name: url.lastPathComponent, url: url)
    }

    public static func parse(_ text: String, name: String, url: URL? = nil) throws -> GCodeFile {
        let lines = text.components(separatedBy: .newlines)
        guard !lines.isEmpty else { throw GCodeError.empty }

        var metadata = GCodeMetadata()
        var commandIndices: [Int] = []
        var layers: [GCodeLayer] = []
        var pendingElapsed: [(seconds: TimeInterval, lineIndex: Int)] = []

        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix(";") {
                absorbComment(line, into: &metadata, layers: &layers, elapsed: &pendingElapsed, at: index)
                continue
            }

            commandIndices.append(index)
            absorbCommand(line, into: &metadata)
        }

        guard !commandIndices.isEmpty else { throw GCodeError.noCommands }

        // Close each layer at its own `;TIME_ELAPSED:` marker where the slicer wrote one,
        // and at the next layer otherwise.
        for position in layers.indices {
            let nextLayerStart = position + 1 < layers.count
                ? layers[position + 1].firstLineIndex
                : lines.count

            if position < pendingElapsed.count {
                let marker = pendingElapsed[position]
                layers[position].elapsedAtEnd = marker.seconds
                // The `min` guards a file whose markers and layers do not pair up one
                // for one, so a layer can never end before it begins.
                layers[position].endLineIndex = max(
                    layers[position].firstLineIndex + 1,
                    min(marker.lineIndex, nextLayerStart)
                )
            } else {
                layers[position].endLineIndex = nextLayerStart
            }
        }

        return GCodeFile(
            name: name,
            url: url,
            lines: lines,
            commandLineIndices: commandIndices,
            layers: layers,
            metadata: metadata
        )
    }

    // MARK: - Comment scraping

    private static func absorbComment(
        _ line: String,
        into metadata: inout GCodeMetadata,
        layers: inout [GCodeLayer],
        elapsed: inout [(seconds: TimeInterval, lineIndex: Int)],
        at index: Int
    ) {
        let body = String(line.dropFirst())

        func value(after key: String) -> String? {
            guard body.hasPrefix(key) else { return nil }
            return String(body.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
        }

        if let flavor = value(after: "FLAVOR:") { metadata.flavor = flavor }
        else if let time = value(after: "TIME:") { metadata.estimatedDuration = TimeInterval(time) }
        else if let height = value(after: "Layer height:") { metadata.layerHeight = Double(height) }
        else if let count = value(after: "LAYER_COUNT:") { metadata.declaredLayerCount = Int(count) }
        else if let machine = value(after: "TARGET_MACHINE.NAME:") { metadata.targetMachine = machine }
        else if let generator = value(after: "Generated with ") { metadata.generator = generator }
        else if let used = value(after: "Filament used:") {
            // "1.36901m" — metres, with the unit stuck to the number.
            metadata.filamentUsedMetres = Double(used.replacingOccurrences(of: "m", with: ""))
        }
        else if let elapsedText = value(after: "TIME_ELAPSED:"), let seconds = TimeInterval(elapsedText) {
            elapsed.append((seconds, index))
        }
        else if let layerText = value(after: "LAYER:"), let number = Int(layerText) {
            layers.append(GCodeLayer(number: number, firstLineIndex: index, endLineIndex: index))
        }
        else if let x = value(after: "MINX:") { metadata.bounds.minX = Double(x) }
        else if let y = value(after: "MINY:") { metadata.bounds.minY = Double(y) }
        else if let z = value(after: "MINZ:") { metadata.bounds.minZ = Double(z) }
        else if let x = value(after: "MAXX:") { metadata.bounds.maxX = Double(x) }
        else if let y = value(after: "MAXY:") { metadata.bounds.maxY = Double(y) }
        else if let z = value(after: "MAXZ:") { metadata.bounds.maxZ = Double(z) }
    }

    /// Notes the things about a command that matter before the print starts.
    private static func absorbCommand(_ line: String, into metadata: inout GCodeMetadata) {
        let code = MarlinConnection.sanitise(line).uppercased()
        guard !code.isEmpty else { return }

        if code.hasPrefix("G28") { metadata.homesItself = true; return }

        let isHotend = code.hasPrefix("M104") || code.hasPrefix("M109")
        let isBed = code.hasPrefix("M140") || code.hasPrefix("M190")
        guard isHotend || isBed, let target = sValue(in: code) else { return }

        if isHotend {
            metadata.maxHotendTarget = max(metadata.maxHotendTarget ?? 0, target)
        } else {
            metadata.maxBedTarget = max(metadata.maxBedTarget ?? 0, target)
        }
    }

    /// The `S` parameter of a command, e.g. 210 from `M109 S210`.
    private static func sValue(in code: String) -> Double? {
        // Scan for a standalone `S`, so the S in a comment-free `M109 S210` is found but
        // a letter inside a word is not.
        var previousWasSeparator = true
        for (offset, character) in code.enumerated() {
            if character == "S", previousWasSeparator {
                let rest = code.dropFirst(offset + 1)
                let digits = rest.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
                if let value = Double(digits) { return value }
            }
            previousWasSeparator = character == " " || character == "\t"
        }
        return nil
    }

    // MARK: - Progress and time

    /// The layer being printed at a given line, or `nil` before the first one starts.
    public func layerIndex(atLineIndex index: Int) -> Int? {
        guard !layers.isEmpty, index >= layers[0].firstLineIndex else { return nil }
        var found: Int?
        for (position, layer) in layers.enumerated() where layer.firstLineIndex <= index {
            found = position
        }
        return found
    }

    /// How far into the print we are, in seconds, using the slicer's own per-layer
    /// timings.
    ///
    /// This is the point of indexing `;TIME_ELAPSED:`: a print is not linear in lines.
    /// A layer of dense infill has far more commands than a tall thin one, so estimating
    /// from "lines sent ÷ lines total" gives a remaining time that lurches around.
    /// Interpolating within the layer the slicer already timed does not.
    public func estimatedElapsed(atLineIndex index: Int) -> TimeInterval? {
        guard metadata.estimatedDuration != nil || !layers.isEmpty else { return nil }
        guard let position = layerIndex(atLineIndex: index) else { return 0 }

        let layer = layers[position]
        let start = position > 0 ? (layers[position - 1].elapsedAtEnd ?? 0) : 0
        guard let end = layer.elapsedAtEnd else { return start }

        let span = max(1, layer.endLineIndex - layer.firstLineIndex)
        let travelled = min(max(0, index - layer.firstLineIndex), span)
        return start + (end - start) * (Double(travelled) / Double(span))
    }

    /// Seconds left, or `nil` when the file carries no timings to work from.
    public func estimatedRemaining(atLineIndex index: Int) -> TimeInterval? {
        guard let total = metadata.estimatedDuration ?? layers.last?.elapsedAtEnd,
              let elapsed = estimatedElapsed(atLineIndex: index)
        else { return nil }
        return max(0, total - elapsed)
    }

    // MARK: - Checking the file against the machine

    /// Everything worth telling the user before they press Print.
    ///
    /// Blocking problems are ones where starting the print would damage something or
    /// waste an hour for certain. Advisory ones are worth a glance and no more.
    public func warnings(for profile: PrinterProfile) -> [GCodeWarning] {
        var warnings: [GCodeWarning] = []

        // Outside the build volume: the nozzle would be driven into the frame, or the
        // firmware would clip the moves and print a deformed object.
        if metadata.bounds.isUsable {
            let bounds = metadata.bounds
            var offending: [String] = []
            if let maxX = bounds.maxX, maxX > profile.maxX { offending.append("X reaches \(MovePlanner.format(maxX)) mm") }
            if let maxY = bounds.maxY, maxY > profile.maxY { offending.append("Y reaches \(MovePlanner.format(maxY)) mm") }
            if let maxZ = bounds.maxZ, maxZ > profile.maxZ { offending.append("Z reaches \(MovePlanner.format(maxZ)) mm") }
            if let minX = bounds.minX, minX < profile.minX { offending.append("X starts at \(MovePlanner.format(minX)) mm") }
            if let minY = bounds.minY, minY < profile.minY { offending.append("Y starts at \(MovePlanner.format(minY)) mm") }

            if !offending.isEmpty {
                warnings.append(GCodeWarning(
                    id: "bounds",
                    severity: .blocking,
                    title: "This file does not fit the printer",
                    detail: "\(offending.joined(separator: ", ")), but this printer's usable area is "
                          + "\(MovePlanner.format(profile.maxX)) × \(MovePlanner.format(profile.maxY)) × "
                          + "\(MovePlanner.format(profile.maxZ)) mm. Re-slice it smaller, or correct the "
                          + "build volume in the printer profile if it is wrong."
                ))
            }
        } else {
            warnings.append(GCodeWarning(
                id: "no-bounds",
                severity: .advisory,
                title: "Nozzle cannot tell how big this print is",
                detail: "The file has no size information in it, so it cannot be checked against the "
                      + "build volume. Watch the first few minutes."
            ))
        }

        if let hotend = metadata.maxHotendTarget, hotend > profile.maxHotendTemperature {
            warnings.append(GCodeWarning(
                id: "hotend-temperature",
                severity: .blocking,
                title: "This file asks for a hotter nozzle than the profile allows",
                detail: "It sets the nozzle to \(MovePlanner.format(hotend)) °C, above the "
                      + "\(MovePlanner.format(profile.maxHotendTemperature)) °C limit in the printer profile."
            ))
        }
        if let bed = metadata.maxBedTarget, bed > profile.maxBedTemperature {
            warnings.append(GCodeWarning(
                id: "bed-temperature",
                severity: .blocking,
                title: "This file asks for a hotter bed than the profile allows",
                detail: "It sets the bed to \(MovePlanner.format(bed)) °C, above the "
                      + "\(MovePlanner.format(profile.maxBedTemperature)) °C limit in the printer profile."
            ))
        }

        // Marlin is what this printer speaks. Another flavour's commands are not
        // gibberish — they are valid commands that mean something different.
        if let flavor = metadata.flavor, flavor.lowercased() != "marlin" {
            warnings.append(GCodeWarning(
                id: "flavour",
                severity: .blocking,
                title: "This file was sliced for a different kind of firmware",
                detail: "It says its flavour is “\(flavor)”, but this printer runs Marlin. Re-slice it "
                      + "in Cura with the printer set to Marlin."
            ))
        }

        if !metadata.homesItself {
            warnings.append(GCodeWarning(
                id: "no-homing",
                severity: .advisory,
                title: "This file never homes the printer",
                detail: "Most files start with G28. Without it the printer begins from wherever it "
                      + "happens to be, so home it yourself on the Prepare screen first."
            ))
        }

        return warnings
    }
}

/// Something the user should know before printing a particular file.
public struct GCodeWarning: Codable, Equatable, Sendable, Identifiable {
    public enum Severity: String, Codable, Sendable, Equatable {
        /// Printing anyway would damage something or certainly fail.
        case blocking
        /// Worth reading once.
        case advisory
    }

    public let id: String
    public let severity: Severity
    public let title: String
    public let detail: String

    public init(id: String, severity: Severity, title: String, detail: String) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}
