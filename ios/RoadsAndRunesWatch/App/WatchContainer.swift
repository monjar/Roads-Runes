import Foundation
import Observation
import RoadsAndRunesCore

/// Dependency container for the Watch app: the ride store, the phone link and
/// the workout session. Wires the three together once at launch.
@MainActor
@Observable
final class WatchContainer {
    let store: RideStore
    let phone: PhoneSessionService
    let workout: WorkoutManager

    init() {
        let store = RideStore()
        let workout = WorkoutManager()
        let phone = PhoneSessionService(store: store)
        self.store = store
        self.workout = workout
        self.phone = phone

        workout.onHeartRate = { [weak store, weak phone] bpm in
            Task { @MainActor in
                store?.localHeartRate = bpm
                phone?.send(heartRate: bpm)
            }
        }
        store.onRideStateChanged = { [weak workout, weak store] state in
            Task { @MainActor in
                guard let workout else { return }
                switch state {
                case .active, .offRoute, .rerouting:
                    workout.startIfNeeded(activity: store?.summary?.activity)
                    workout.resume()
                case .paused:
                    workout.pause()
                case .completed, .cancelled:
                    workout.end()
                default:
                    break
                }
            }
        }
        phone.activate()
        Task { await workout.requestAuthorization() }
    }

    func send(_ command: WatchCommand) {
        switch command {
        case .pause:
            store.markPaused(true)
        case .resume:
            store.markPaused(false)
        case .end:
            store.markEnded()
        }
        phone.send(command: command)
    }
}
