import CoreHaptics
import Foundation
import RoadsAndRunesCore
import UIKit

/// Plays the signature haptics (0.8.0, Core `SignaturePatterns`) at rest only:
/// on Journey's end and when something is opened in the app, never while a
/// journey is being recorded. CoreHaptics where the phone has a Taptic Engine,
/// which the system silences when System Haptics is off in Settings; elsewhere a
/// plain notification haptic, which follows the same switch.
@MainActor
final class SignatureHapticsPlayer {
    static let shared = SignatureHapticsPlayer()

    /// Whether a journey is being recorded; nothing plays while it is.
    var isRiding: () -> Bool = { false }

    private var engine: CHHapticEngine?
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    /// Tests and previews set this to keep the engine off.
    var enabled = true

    func play(_ haptic: SignatureHaptic) {
        guard enabled, !isRiding() else { return }
        guard supportsHaptics, let pattern = try? Self.pattern(haptic.pattern), let engine = startedEngine() else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }
        do {
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    /// A find, felt: the shimmer for a Rare or Legendary one, nothing for the rest.
    func play(find rarity: String?) {
        if let haptic = SignatureHaptic.forFind(rarity: rarity) { play(haptic) }
    }

    private func startedEngine() -> CHHapticEngine? {
        if let engine { return engine }
        guard let made = try? CHHapticEngine() else { return nil }
        made.playsHapticsOnly = true
        made.isAutoShutdownEnabled = true
        // The system stops the engine when the app goes away; start it again next time.
        made.resetHandler = { [weak made] in try? made?.start() }
        made.stoppedHandler = { _ in }
        do {
            try made.start()
        } catch {
            return nil
        }
        engine = made
        return made
    }

    /// Core's pattern data as a CoreHaptics pattern.
    static func pattern(_ data: SignaturePattern) throws -> CHHapticPattern {
        let events = data.events.map { event in
            CHHapticEvent(
                eventType: event.kind == .continuous ? .hapticContinuous : .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(event.intensity)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(event.sharpness)),
                ],
                relativeTime: event.time,
                duration: event.duration
            )
        }
        var curves: [CHHapticParameterCurve] = []
        if let first = data.intensityCurve.first {
            curves.append(CHHapticParameterCurve(
                parameterID: .hapticIntensityControl,
                controlPoints: data.intensityCurve.map {
                    CHHapticParameterCurve.ControlPoint(relativeTime: $0.time - first.time, value: Float($0.value))
                },
                relativeTime: first.time
            ))
        }
        return try CHHapticPattern(events: events, parameterCurves: curves)
    }
}
