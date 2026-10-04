import Foundation

/// The reckoning's fight lines (docs/WORLD.md): numbers bare, no gore, one
/// sentence for what happened and one for what would have done it.
public enum FightCopy {
    /// The quarry first, then what was seen off, then what got away, then what did not notice.
    public static func ordered(_ reports: [FightReport], quarryId: String?) -> [FightReport] {
        func rank(_ r: FightReport) -> Int {
            if let quarryId, r.id.uuidString.lowercased() == quarryId.lowercased() { return 0 }
            switch r.outcome {
            case "SEEN_OFF": return 1
            case "LOOSENED": return 2
            default: return 3
            }
        }
        return reports.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// "Grey Stag got away at 31 of 400. Another 13 m of height would have done it.
    /// It is there three more days."
    public static func line(_ report: FightReport, units: Units = .metric, now: Date = Date()) -> String {
        let name = report.name ?? "It"
        switch report.outcome {
        case "SEEN_OFF":
            return "\(name) was seen off. \(finisher(report.finisher))"
        case "LOOSENED":
            var parts = ["\(name) got away at \(report.holdAfter) of \(report.holdMax)."]
            if let would = report.wouldHaveDone.flatMap({ wouldHaveDone($0, units: units) }) { parts.append(would) }
            if let expiry = report.expiresAt { parts.append(RewardCopy.staying(until: expiry, now: now)) }
            return parts.joined(separator: " ")
        default:
            return "\(name) let you pass."
        }
    }

    static func finisher(_ kind: String?) -> String {
        switch kind?.uppercased() {
        case "ROAD": return "The road did it."
        case "GROUND": return "New ground did it."
        case "CLIMB": return "Height did it."
        case "RUNE": return "Its rune did it."
        case "WORD": return "The word did it."
        default: return "It had had enough."
        }
    }

    /// "Another 13 m of height would have done it."
    public static func wouldHaveDone(_ would: WouldHaveDone, units: Units = .metric) -> String? {
        let formatter = UnitFormatter(units: units)
        switch would.kind.uppercased() {
        case "CLIMB": return "Another \(formatter.elevation(meters: would.units)) of height would have done it."
        case "ROAD": return "Another \(formatter.distance(meters: would.units)) of the road would have done it."
        case "GROUND":
            let n = Int(would.units.rounded(.up))
            return "\(RewardCopy.spelled(n).capitalizedFirst) more \(n == 1 ? "patch" : "patches") of new ground would have done it."
        case "RUNE": return "Its rune would have done it."
        case "WORD": return "The word would have done it."
        default: return nil
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
