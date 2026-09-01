import Foundation

/// One of the four quick manual-levelling positions around the bed.
public enum BedLevelCorner: String, CaseIterable, Sendable, Equatable, Identifiable {
    case frontLeft
    case frontRight
    case rearRight
    case rearLeft

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .frontLeft:  return "front-left"
        case .frontRight: return "front-right"
        case .rearRight:  return "rear-right"
        case .rearLeft:   return "rear-left"
        }
    }
}

/// A resolved corner coordinate inside the configured build volume.
public struct BedLevelPoint: Sendable, Equatable {
    public let corner: BedLevelCorner
    public let x: Double
    public let y: Double

    public init(corner: BedLevelCorner, x: Double, y: Double) {
        self.corner = corner
        self.x = x
        self.y = y
    }
}
