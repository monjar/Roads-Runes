import Foundation

/// Signature haptics (0.8.0): four patterns felt at rest only — on Journey's end
/// and when something is opened in the app, never on a journey. Kept here as
/// plain data so they can be tested without a device; the app turns them into
/// CoreHaptics patterns and plays them.
public enum SignatureHaptic: String, CaseIterable, Sendable {
    /// A chest opened: two knocks and a rattle.
    case chest
    /// A legend's phase broken: a swell.
    case phaseBroken
    /// A legend defeated: a swell, then three knocks.
    case legendDefeated
    /// A Rare or Legendary item found: a shimmer.
    case rareFind

    public var pattern: SignaturePattern {
        switch self {
        case .chest: return SignaturePatterns.chest
        case .phaseBroken: return SignaturePatterns.swell(from: 0)
        case .legendDefeated: return SignaturePatterns.legendDefeated
        case .rareFind: return SignaturePatterns.shimmer
        }
    }

    /// The shimmer for a Rare or Legendary find; nothing for a Common one.
    public static func forFind(rarity: String?) -> SignatureHaptic? {
        switch rarity?.uppercased() {
        case ItemRarity.rare, ItemRarity.legendary: return .rareFind
        default: return nil
        }
    }

    /// What a legend's line on Journey's end is felt as, if anything.
    public static func forLegend(_ outcome: LegendOutcome?) -> SignatureHaptic? {
        guard let outcome else { return nil }
        if outcome.defeated { return .legendDefeated }
        return outcome.phaseBroken ? .phaseBroken : nil
    }
}

/// One haptic event: a tap (transient) or a held buzz (continuous).
public struct HapticEvent: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case transient, continuous
    }

    public var kind: Kind
    /// Seconds from the start of the pattern.
    public var time: Double
    /// Seconds a continuous event lasts; 0 for a tap.
    public var duration: Double
    /// 0…1: how strong.
    public var intensity: Double
    /// 0…1: dull thud to crisp click.
    public var sharpness: Double

    public init(kind: Kind, time: Double, duration: Double = 0, intensity: Double, sharpness: Double) {
        self.kind = kind
        self.time = time
        self.duration = duration
        self.intensity = intensity
        self.sharpness = sharpness
    }

    public static func tap(at time: Double, intensity: Double, sharpness: Double) -> HapticEvent {
        HapticEvent(kind: .transient, time: time, intensity: intensity, sharpness: sharpness)
    }

    /// When it stops.
    public var end: Double { time + duration }
}

/// A point on the intensity curve that shapes continuous events: the swell.
public struct HapticCurvePoint: Hashable, Sendable {
    public var time: Double
    /// 0…1, multiplying the events' own intensity.
    public var value: Double

    public init(time: Double, value: Double) {
        self.time = time
        self.value = value
    }
}

/// A whole pattern: its events in time order, and the intensity curve laid over
/// its continuous events (empty when it has none).
public struct SignaturePattern: Hashable, Sendable {
    public var events: [HapticEvent]
    public var intensityCurve: [HapticCurvePoint]

    public init(events: [HapticEvent], intensityCurve: [HapticCurvePoint] = []) {
        self.events = events.sorted { $0.time < $1.time }
        self.intensityCurve = intensityCurve.sorted { $0.time < $1.time }
    }

    /// When the last event ends.
    public var duration: Double { events.map(\.end).max() ?? 0 }
    public var taps: [HapticEvent] { events.filter { $0.kind == .transient } }
    public var buzzes: [HapticEvent] { events.filter { $0.kind == .continuous } }
}

/// The four patterns' numbers.
public enum SignaturePatterns {
    /// Two firm, dull knocks on a lid, then a light rattle of what is inside.
    public static let chest: SignaturePattern = {
        let knocks = [HapticEvent.tap(at: 0, intensity: 1.0, sharpness: 0.3), .tap(at: 0.16, intensity: 0.85, sharpness: 0.3)]
        let rattle = (0..<6).map { i in
            HapticEvent.tap(at: 0.42 + Double(i) * 0.05, intensity: 0.5 - Double(i) * 0.05, sharpness: 0.8)
        }
        return SignaturePattern(events: knocks + rattle)
    }()

    /// How long the swell lasts.
    public static let swellSeconds = 1.1

    /// One held buzz that grows to full and falls away.
    public static func swell(from start: Double) -> SignaturePattern {
        SignaturePattern(
            events: [HapticEvent(kind: .continuous, time: start, duration: swellSeconds, intensity: 1.0, sharpness: 0.4)],
            intensityCurve: [
                HapticCurvePoint(time: start, value: 0.1),
                HapticCurvePoint(time: start + swellSeconds * 0.7, value: 1.0),
                HapticCurvePoint(time: start + swellSeconds, value: 0.0),
            ]
        )
    }

    /// The swell, then three knocks.
    public static let legendDefeated: SignaturePattern = {
        let rising = SignaturePatterns.swell(from: 0)
        let knocks = (0..<3).map { i in HapticEvent.tap(at: swellSeconds + 0.2 + Double(i) * 0.2, intensity: 1.0, sharpness: 0.5) }
        return SignaturePattern(events: rising.events + knocks, intensityCurve: rising.intensityCurve)
    }()

    /// Quick, light, crisp taps that rise and fall: a glint.
    public static let shimmer: SignaturePattern = {
        let count = 9
        let events = (0..<count).map { i -> HapticEvent in
            let hump = sin(Double(i) / Double(count - 1) * .pi)
            return .tap(at: Double(i) * 0.06, intensity: 0.25 + 0.35 * hump, sharpness: 0.95)
        }
        return SignaturePattern(events: events)
    }()
}
