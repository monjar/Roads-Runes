import Foundation
import HealthKit
import RoadsAndRunesCore

/// Optional HealthKit integration (spec §38). Every method is a no-op when
/// Health is unavailable or denied; the app never depends on it.
@MainActor
final class HealthKitService: ObservableObject {
    @Published private(set) var isAvailable: Bool
    @Published private(set) var isAuthorized = false

    private let store = HKHealthStore()
    private var builder: HKWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?
    private var heartRateQuery: HKAnchoredObjectQuery?
    private var lastDistance: Double = 0
    private var lastEnergy: Double = 0
    /// Cycling distance for rides, walking/running distance for the rest.
    private var distanceType = HKQuantityType(.distanceCycling)

    var onHeartRate: ((Int) -> Void)?

    /// `enabled: false` (in-memory containers: previews and unit tests) keeps every call a
    /// no-op, so tests never block on the Health permission sheet.
    init(enabled: Bool = true) {
        isAvailable = enabled && HKHealthStore.isHealthDataAvailable()
    }

    private var typesToShare: Set<HKSampleType> {
        [HKObjectType.workoutType(), HKSeriesType.workoutRoute(),
         HKQuantityType(.distanceCycling), HKQuantityType(.distanceWalkingRunning), HKQuantityType(.activeEnergyBurned)]
    }

    private var typesToRead: Set<HKObjectType> {
        [HKQuantityType(.heartRate), HKQuantityType(.distanceCycling), HKQuantityType(.distanceWalkingRunning),
         HKQuantityType(.activeEnergyBurned)]
    }

    func requestAuthorization() async {
        guard isAvailable else { return }
        do {
            try await store.requestAuthorization(toShare: typesToShare, read: typesToRead)
            isAuthorized = store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
        } catch {
            isAuthorized = false
        }
    }

    func beginWorkout(startDate: Date, activity: Activity = .ride) {
        guard isAvailable, isAuthorized else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity.workoutType
        configuration.locationType = .outdoor
        distanceType = activity == .ride ? HKQuantityType(.distanceCycling) : HKQuantityType(.distanceWalkingRunning)
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        self.builder = builder
        routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        lastDistance = 0
        lastEnergy = 0
        builder.beginCollection(withStart: startDate) { _, _ in }
        startHeartRateQuery(from: startDate)
    }

    func record(fix: LocationFix) {
        guard let routeBuilder, let accuracy = fix.horizontalAccuracy, accuracy <= 50 else { return }
        let location = CLLocationFromFix(fix)
        routeBuilder.insertRouteData([location]) { _, _ in }
    }

    func update(distanceMeters: Double, activeCalories: Double?, at date: Date) {
        guard let builder else { return }
        var samples: [HKSample] = []
        if distanceMeters > lastDistance {
            let quantity = HKQuantity(unit: .meter(), doubleValue: distanceMeters - lastDistance)
            samples.append(HKQuantitySample(type: distanceType, quantity: quantity, start: date.addingTimeInterval(-1), end: date))
            lastDistance = distanceMeters
        }
        if let activeCalories, activeCalories > lastEnergy {
            let quantity = HKQuantity(unit: .kilocalorie(), doubleValue: activeCalories - lastEnergy)
            samples.append(HKQuantitySample(type: HKQuantityType(.activeEnergyBurned), quantity: quantity, start: date.addingTimeInterval(-1), end: date))
            lastEnergy = activeCalories
        }
        guard !samples.isEmpty else { return }
        builder.add(samples) { _, _ in }
    }

    /// Ends the workout and returns its UUID (sent to the backend as `healthKitWorkoutId`).
    func endWorkout(endDate: Date) async -> String? {
        guard let builder else { return nil }
        stopHeartRateQuery()
        defer { self.builder = nil; self.routeBuilder = nil }
        do {
            try await builder.endCollection(at: endDate)
            let workout = try await builder.finishWorkout()
            if let routeBuilder, let workout {
                try await routeBuilder.finishRoute(with: workout, metadata: nil)
            }
            return workout?.uuid.uuidString
        } catch {
            return nil
        }
    }

    func discard() {
        stopHeartRateQuery()
        builder?.discardWorkout()
        builder = nil
        routeBuilder = nil
    }

    private func startHeartRateQuery(from start: Date) {
        let type = HKQuantityType(.heartRate)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit) { [weak self] _, samples, _, _, _ in
            self?.handle(samples: samples)
        }
        query.updateHandler = { [weak self] _, samples, _, _, _ in
            self?.handle(samples: samples)
        }
        store.execute(query)
        heartRateQuery = query
    }

    private nonisolated func handle(samples: [HKSample]?) {
        guard let last = samples?.compactMap({ $0 as? HKQuantitySample }).last else { return }
        let bpm = Int(last.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))
        Task { @MainActor in self.onHeartRate?(bpm) }
    }

    private func stopHeartRateQuery() {
        if let heartRateQuery { store.stop(heartRateQuery) }
        heartRateQuery = nil
    }
}

extension Activity {
    var workoutType: HKWorkoutActivityType {
        switch self {
        case .run: return .running
        case .walk: return .walking
        default: return .cycling
        }
    }
}

import CoreLocation

private func CLLocationFromFix(_ fix: LocationFix) -> CLLocation {
    CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude),
        altitude: fix.altitude ?? 0,
        horizontalAccuracy: fix.horizontalAccuracy ?? 10,
        verticalAccuracy: fix.altitude == nil ? -1 : 10,
        course: -1,
        speed: fix.speed ?? -1,
        timestamp: fix.timestamp
    )
}
