import Foundation
import Observation
import RoadsAndRunesCore

/// Dependency container for the Watch app: the ride store, the phone link, the
/// workout session and the complication. Wires them together once at launch.
@MainActor
@Observable
final class WatchContainer {
    let store: RideStore
    let phone: PhoneSessionService
    let workout: WorkoutManager
    let face: ComplicationWriter

    init() {
        let store = RideStore()
        let workout = WorkoutManager()
        let phone = PhoneSessionService(store: store)
        let face = ComplicationWriter()
        self.store = store
        self.workout = workout
        self.phone = phone
        self.face = face

        // Next up as last heard, until the phone speaks; the complication follows the store.
        store.restore(idle: face.keptIdle())
        store.onFaceChanged = { [weak store, weak face] in
            guard let store else { return }
            face?.publish(idle: store.idle, quarry: store.quarry)
        }

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

    /// A journey asked for from Next up (0.7.3): "Planning…" until the ride comes,
    /// and a plain failure if it has not come by `RideStore.planningTimeout`.
    func requestStart(_ request: WatchStartRequest) {
        guard phone.requestStart(request) else { return }
        Task { [weak store] in
            try? await Task.sleep(for: .seconds(RideStore.planningTimeout))
            store?.expirePlanning()
        }
    }
}
