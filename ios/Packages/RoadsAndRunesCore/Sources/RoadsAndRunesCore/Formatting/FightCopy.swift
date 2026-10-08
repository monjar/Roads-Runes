import Foundation

/// Journey's end's fight lines (docs/VOICE.md): what happened first, then what
/// would have done it. Numbers carry a label, no gore.
public enum FightCopy {
    /// The quarry first, then what was defeated, then what got away weakened, then what did not notice.
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

    /// "Grey Stag escaped, weakened. Health 31 / 400. 13 m more climbing would have
    /// defeated it. It stays three more days."
    public static func line(_ report: FightReport, units: Units = .metric, now: Date = Date()) -> String {
        let name = report.name ?? "The creature"
        switch report.outcome {
        case "SEEN_OFF":
            return ["\(name) defeated!", finisher(report.finisher)].compactMap { $0 }.joined(separator: " ")
        case "LOOSENED":
            var parts = ["\(name) escaped, weakened. Health \(report.holdAfter) / \(report.holdMax)."]
            if let would = report.wouldHaveDone.flatMap({ wouldHaveDone($0, units: units) }) { parts.append(would) }
            if let expiry = report.expiresAt { parts.append(RewardCopy.staying(until: expiry, now: now)) }
            return parts.joined(separator: " ")
        default:
            return "You passed \(name) without a fight."
        }
    }

    /// What landed the last blow: "Finished with climbing."
    static func finisher(_ kind: String?) -> String? {
        switch kind?.uppercased() {
        case "ROAD": return "Finished with distance."
        case "GROUND": return "Finished with exploring."
        case "CLIMB": return "Finished with climbing."
        case "RUNE": return "Finished with a rune ride."
        case "WORD": return "Finished with a note."
        default: return nil
        }
    }

    /// "13 m more climbing would have defeated it."
    public static func wouldHaveDone(_ would: WouldHaveDone, units: Units = .metric) -> String? {
        let formatter = UnitFormatter(units: units)
        switch would.kind.uppercased() {
        case "CLIMB": return "\(formatter.elevation(meters: would.units)) more climbing would have defeated it."
        case "ROAD": return "\(formatter.distance(meters: would.units)) more distance would have defeated it."
        case "GROUND":
            let n = Int(would.units.rounded(.up))
            return "\(RewardCopy.spelled(n).capitalizedFirst) more unexplored \(n == 1 ? "tile" : "tiles") would have defeated it."
        case "RUNE": return "A rune ride would have defeated it."
        case "WORD": return "A note would have defeated it."
        default: return nil
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
