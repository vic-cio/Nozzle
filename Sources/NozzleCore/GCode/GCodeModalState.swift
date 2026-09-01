import Foundation

/// The modal settings a G-code file is relying on at a given point in the stream.
///
/// G-code is stateful in ways that are easy to forget. `G91` stays on until something
/// says `G90`; `M83` stays on until `M82`; and a `G1` with no `F` runs at whatever
/// feedrate was last set — possibly thousands of lines earlier.
///
/// That matters for pause. Parking the nozzle means sending moves of Nozzle's own, and
/// every one of them changes something the file is going to rely on when it carries on.
/// Send `G91` to lift and forget to restore it, and the next print move goes to a
/// relative destination. Lift at `F600` and the rest of the layer prints at 600 mm/min,
/// which is a visible band in the part at best.
///
/// So the streamer watches what it sends and keeps this alongside it, and the pause and
/// resume plans put every one of these back exactly as the file left it.
///
/// A value type with no clock and no port: hand it lines, assert on the result.
public struct GCodeModalState: Equatable, Sendable {

    /// `G91` is on — coordinates are distances rather than destinations.
    public var relativeMoves = false

    /// `M83` is on. Marlin keeps this flag separately from `G90`/`G91`, and Cura's
    /// header sets it explicitly, so the two must be tracked and restored separately.
    public var relativeExtrusion = false

    /// The last `F` seen on a move, in mm/min. `nil` until the file sets one.
    public var feedrate: Double?

    public init() {}

    /// Updates the state from one line of the file.
    ///
    /// Safe to call with comments, blank lines and anything else the file contains;
    /// only the commands that carry modal state are acted on.
    public mutating func observe(_ line: String) {
        let code = Self.stripComment(line)
        guard let command = Self.command(in: code) else { return }

        switch command {
        case ("G", 90): relativeMoves = false
        case ("G", 91): relativeMoves = true
        case ("M", 82): relativeExtrusion = false
        case ("M", 83): relativeExtrusion = true

        // Arcs carry a feedrate too. Cura does not emit them by default, but a file
        // sliced elsewhere may, and missing one would leave a stale feedrate behind.
        case ("G", 0), ("G", 1), ("G", 2), ("G", 3):
            if let f = Self.value(of: "F", in: code), f > 0 { feedrate = f }

        default:
            break
        }
    }

    /// Applies every line of a file up to (and including) `index`.
    ///
    /// Only used by tests and tooling — the streamer builds the state incrementally as
    /// it sends, which costs nothing and cannot drift from what was actually on the wire.
    public static func replaying(_ lines: [String], through index: Int) -> GCodeModalState {
        var state = GCodeModalState()
        for line in lines.prefix(index + 1) { state.observe(line) }
        return state
    }

    // MARK: - Parsing

    static func stripComment(_ line: String) -> String {
        guard let semicolon = line.firstIndex(of: ";") else { return line }
        return String(line[line.startIndex..<semicolon])
    }

    /// The leading command word: `G1 X10` → ("G", 1).
    ///
    /// Matched on the number rather than a string prefix, because `M8` is a prefix of
    /// `M83` and confusing the two would turn "coolant on" into "relative extrusion".
    static func command(in code: String) -> (String, Int)? {
        let trimmed = code.drop { $0 == " " || $0 == "\t" }
        guard let letter = trimmed.first, letter == "G" || letter == "M" || letter == "g" || letter == "m" else {
            return nil
        }
        let digits = trimmed.dropFirst().prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        return (String(letter).uppercased(), number)
    }

    /// The value of one parameter word, e.g. `F` in `G1 X10 F1500`.
    ///
    /// A parameter letter is one that does not directly follow another letter. That
    /// admits the unspaced form Marlin also accepts (`G1X10F1500`) while refusing to
    /// read the `F` out of the middle of some other word.
    static func value(of letter: Character, in code: String) -> Double? {
        let target = Character(letter.uppercased())
        var index = code.startIndex
        var previous: Character?

        while index < code.endIndex {
            let character = code[index]
            if Character(character.uppercased()) == target, previous?.isLetter != true {
                let rest = code[code.index(after: index)...]
                let digits = rest.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
                if let value = Double(digits) { return value }
            }
            previous = character
            index = code.index(after: index)
        }
        return nil
    }
}
