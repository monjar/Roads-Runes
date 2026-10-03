import Foundation

/// What the two reminders say. They used to promise "a chest on the way" and a
/// bounty "closer than you think" whether or not either was true; now a reminder
/// names the thing and says how far it is, or says nothing about it.
public enum NudgeCopy {
    public struct Lure: Hashable, Sendable {
        public var name: String
        public var kind: WorldObjectKind
        public var meters: Double

        public init(name: String, kind: WorldObjectKind, meters: Double) {
            self.name = name
            self.kind = kind
            self.meters = meters
        }

        public init(_ object: WorldObject, from position: Coordinate) {
            self.init(name: object.kind == .collectable ? (object.piece ?? object.name) : object.name, kind: object.kind, meters: GeoMath.distance(position, object.coordinate))
        }

        /// "The Gutter Drake", "An Old chest", "Raido".
        var named: String {
            switch kind {
            case .monster: return "The \(name)"
            case .chest: return "\("AEIOUaeiou".contains(name.prefix(1)) ? "An" : "A") \(name)"
            default: return name
            }
        }
    }

    /// The evening reminder that today has not been kept yet.
    public static func streak(days: Int, activity: Activity, bounty: Lure?, nearest: Lure?, units: Units = .metric) -> (title: String, body: String) {
        let formatter = UnitFormatter(units: units)
        let title = "\(LoreCopy.daysKept(days)). Today not yet."
        if let bounty {
            return (title, "\(bounty.named) is \(formatter.distance(meters: bounty.meters)) away and worth double till midnight. One kilometre keeps the days.")
        }
        if let nearest {
            return (title, "One kilometre keeps it alive. \(nearest.named) is \(formatter.distance(meters: nearest.meters)) away.")
        }
        return (title, "One kilometre keeps it alive. A short \(activity.noun) will do.")
    }

    /// The morning reminder: tomorrow's bounty is not placed until the world is looked at, so nothing is said of where.
    public static func bountyMorning() -> (title: String, body: String) {
        ("Today's bounty is out", "One monster, twice the coins, gone at midnight.")
    }

    /// The things worth naming in tonight's reminder: today's bounty if it is still
    /// out, and the nearest thing that will still be there when the reminder fires.
    public static func lures(among objects: [WorldObject], from position: Coordinate, stillThereAt fireDate: Date, within meters: Double = 3000) -> (bounty: Lure?, nearest: Lure?) {
        let live = objects.filter { $0.status == .spawned && $0.expiresAt > fireDate }
        let bounty = live.first { $0.isBounty }.map { Lure($0, from: position) }
        let nearest = live.filter { !$0.isBounty }
            .map { Lure($0, from: position) }
            .filter { $0.meters <= meters }
            .min { $0.meters < $1.meters }
        return (bounty.flatMap { $0.meters <= meters * 2 ? $0 : nil }, nearest)
    }
}
