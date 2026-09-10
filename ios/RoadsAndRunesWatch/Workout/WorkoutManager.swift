import Foundation
import HealthKit
import Observation

/// Runs the cycling workout session on the Watch so heart rate streams and
/// the workout continues while the phone is locked or disconnected.
@MainActor
@Observable
final class WorkoutManager: NSObject {
    private(set) var heartRate: Int?
    private(set) var isRunning = false
    private(set) var isAuthorized = false

    @ObservationIgnored var onHeartRate: ((Int) -> Void)?

    private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [HKObjectType.workoutType(), HKQuantityType(.activeEnergyBurned), HKQuantityType(.distanceCycling)]
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned), HKQuantityType(.distanceCycling)]
        do {
            try await store.requestAuthorization(toShare: share, read: read)
            isAuthorized = true
        } catch {
            isAuthorized = false
        }
    }

    func startIfNeeded() {
        guard session == nil, HKHealthStore.isHealthDataAvailable() else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .outdoor
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            let start = Date()
            session.startActivity(with: start)
            builder.beginCollection(withStart: start) { _, _ in }
            isRunning = true
        } catch {
            session = nil
            builder = nil
        }
    }

    func pause() {
        session?.pause()
    }

    func resume() {
        guard let session, session.state == .paused else { return }
        session.resume()
    }

    func end() {
        guard let session, let builder else { return }
        session.end()
        builder.endCollection(withEnd: Date()) { _, _ in
            builder.finishWorkout { _, _ in }
        }
        self.session = nil
        self.builder = nil
        isRunning = false
    }

    private func process(statistics: HKStatistics?) {
        guard let statistics, statistics.quantityType == HKQuantityType(.heartRate) else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        guard let value = statistics.mostRecentQuantity()?.doubleValue(for: unit) else { return }
        let bpm = Int(value.rounded())
        heartRate = bpm
        onHeartRate?(bpm)
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            self.isRunning = toState == .running
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.isRunning = false
        }
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let statistics: [HKStatistics] = collectedTypes.compactMap { type in
            guard let quantityType = type as? HKQuantityType else { return nil }
            return workoutBuilder.statistics(for: quantityType)
        }
        Task { @MainActor in
            for item in statistics {
                self.process(statistics: item)
            }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
