import XCTest
@testable import RoadsAndRunesCore

final class ObjectiveTrackerTests: XCTestCase {
    private let start = SampleData.origin
    private let target = GeoMath.destination(from: SampleData.origin, bearingDegrees: 45, distanceMeters: 1500)
    private let now = SampleData.referenceDate

    private func objectives() -> [Objective] {
        [
            Objective(id: SampleData.objectiveVisitId, objectiveType: .visitLocation, title: "Visit",
                      latitude: target.latitude, longitude: target.longitude, radiusMeters: 50, required: true, order: 1,
                      progress: ObjectiveProgress(current: 0, target: 1)),
            Objective(id: SampleData.objectiveDistanceId, objectiveType: .completeDistance, title: "Ride 2 km",
                      targetMeters: 2000, required: true, order: 2, progress: ObjectiveProgress(current: 0, target: 2000)),
            Objective(id: SampleData.objectiveReturnId, objectiveType: .returnToStart, title: "Return",
                      radiusMeters: 100, required: true, order: 3, progress: ObjectiveProgress(current: 0, target: 1)),
        ]
    }

    private func update(_ tracker: inout ObjectiveTracker, at position: Coordinate, distance: Double, gain: Double = 0, newTerritory: Double = 0) -> [ObjectiveEvent] {
        tracker.update(position: position, distanceMeters: distance, elevationGainMeters: gain, newTerritoryMeters: newTerritory, timestamp: now)
    }

    func testVisitLocationNeedsTwoConsecutiveFixes() {
        var tracker = ObjectiveTracker(objectives: objectives(), start: start)
        XCTAssertTrue(update(&tracker, at: target, distance: 500).isEmpty)
        let events = update(&tracker, at: target, distance: 520)
        XCTAssertEqual(events.map { $0.objectiveId }, [SampleData.objectiveVisitId])
        XCTAssertEqual(events.first?.latitude ?? 0, target.latitude, accuracy: 1e-9)
        XCTAssertTrue(tracker.completedObjectiveIDs.contains(SampleData.objectiveVisitId))
        // Never emitted twice.
        XCTAssertTrue(update(&tracker, at: target, distance: 540).isEmpty)
    }

    func testVisitLocationResetsWhenLeavingRadius() {
        var tracker = ObjectiveTracker(objectives: objectives(), start: start)
        XCTAssertTrue(update(&tracker, at: target, distance: 500).isEmpty)
        let away = GeoMath.destination(from: target, bearingDegrees: 0, distanceMeters: 80)
        XCTAssertTrue(update(&tracker, at: away, distance: 580).isEmpty)
        XCTAssertTrue(update(&tracker, at: target, distance: 660).isEmpty)
        XCTAssertFalse(update(&tracker, at: target, distance: 700).isEmpty)
    }

    func testDistanceObjective() {
        var tracker = ObjectiveTracker(objectives: objectives(), start: start)
        let mid = GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: 800)
        XCTAssertTrue(update(&tracker, at: mid, distance: 1999).isEmpty)
        let events = update(&tracker, at: mid, distance: 2000)
        XCTAssertEqual(events.map { $0.objectiveId }, [SampleData.objectiveDistanceId])
        XCTAssertEqual(events.first?.value, 2000)
    }

    func testReturnToStartRequiresOneKilometre() {
        var tracker = ObjectiveTracker(objectives: objectives(), start: start)
        XCTAssertTrue(update(&tracker, at: start, distance: 0).isEmpty)
        XCTAssertTrue(update(&tracker, at: start, distance: 999).isEmpty)
        let nearStart = GeoMath.destination(from: start, bearingDegrees: 180, distanceMeters: 40)
        let events = update(&tracker, at: nearStart, distance: 1200)
        XCTAssertEqual(events.map { $0.objectiveId }, [SampleData.objectiveReturnId])
        XCTAssertEqual(tracker.completedObjectiveIDs.count, 1)
    }

    func testElevationAndNewRoadsObjectives() {
        let climb = Objective(id: UUID(), objectiveType: .completeClimb, title: "Climb", targetElevationMeters: 150, required: true, order: 1,
                              progress: ObjectiveProgress(current: 0, target: 150))
        let roads = Objective(id: UUID(), objectiveType: .exploreNewRoads, title: "New roads", targetMeters: 3000, required: true, order: 2,
                              progress: ObjectiveProgress(current: 0, target: 3000))
        let photo = Objective(id: UUID(), objectiveType: .photoLocation, title: "Photo", latitude: start.latitude, longitude: start.longitude,
                              radiusMeters: 50, required: false, order: 3, progress: ObjectiveProgress(current: 0, target: 1))
        var tracker = ObjectiveTracker(objectives: [climb, roads, photo], start: start)
        XCTAssertTrue(update(&tracker, at: start, distance: 5000, gain: 149, newTerritory: 2999).isEmpty)
        let events = update(&tracker, at: start, distance: 5100, gain: 150, newTerritory: 3000)
        XCTAssertEqual(Set(events.map { $0.objectiveId }), Set([climb.id, roads.id]))
        // Photo objectives are never auto-completed, even when standing on the spot.
        XCTAssertTrue(update(&tracker, at: start, distance: 5200, gain: 200, newTerritory: 4000).isEmpty)
        XCTAssertFalse(tracker.completedObjectiveIDs.contains(photo.id))
        XCTAssertNotNil(tracker.markCompleted(photo.id, at: start, timestamp: now))
        XCTAssertNil(tracker.markCompleted(photo.id, at: start, timestamp: now))
    }

    func testVisitMultipleLocationsFromExtra() {
        let a = GeoMath.destination(from: start, bearingDegrees: 0, distanceMeters: 700)
        let b = GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: 700)
        let extra: [String: JSONValue] = [
            "cells": .array([
                .object(["h3": .string("cell-a"), "latitude": .number(a.latitude), "longitude": .number(a.longitude)]),
                .object(["h3": .string("cell-b"), "latitude": .number(b.latitude), "longitude": .number(b.longitude)]),
            ]),
        ]
        let objective = Objective(id: UUID(), objectiveType: .visitMultipleLocations, title: "Corners", required: true, order: 1,
                                  progress: ObjectiveProgress(current: 0, target: 2), extra: extra)
        var tracker = ObjectiveTracker(objectives: [objective], start: start)
        XCTAssertTrue(update(&tracker, at: a, distance: 700).isEmpty)
        XCTAssertEqual(tracker.visitedCells(for: objective.id), ["cell-a"])
        XCTAssertEqual(tracker.progress(for: objective, distanceMeters: 700, elevationGainMeters: 0, newTerritoryMeters: 0).current, 1)
        let events = update(&tracker, at: b, distance: 1700)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.objectiveId, objective.id)
    }

    func testAlreadyCompletedObjectivesAreSkipped() {
        var done = objectives()
        done[1].status = .completed
        var tracker = ObjectiveTracker(objectives: done, start: start)
        XCTAssertTrue(tracker.completedObjectiveIDs.contains(SampleData.objectiveDistanceId))
        // Away from both the target and the start: the completed distance objective must not
        // be re-emitted even though 5 km exceeds its target, and nothing else completes.
        let elsewhere = GeoMath.destination(from: start, bearingDegrees: 225, distanceMeters: 2000)
        XCTAssertTrue(update(&tracker, at: elsewhere, distance: 5000).isEmpty)
        XCTAssertEqual(tracker.pendingObjectives.count, 2)
        // Returning to the start now legitimately completes only the return objective.
        let events = update(&tracker, at: start, distance: 7000)
        XCTAssertEqual(events.map { $0.objectiveId }, [SampleData.objectiveReturnId])
        XCTAssertEqual(tracker.pendingObjectives.count, 1)
    }
}
