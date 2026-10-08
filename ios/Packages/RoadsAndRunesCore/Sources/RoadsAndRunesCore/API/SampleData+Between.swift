import Foundation

/// Between rides (0.7.3): a pledge, letters and a sealed quest for previews and tests.
extension SampleData {
    public static let sealedQuestId = UUID(uuidString: "5ea1ed00-0000-4000-8000-000000000073")!
    public static let sealedObjectiveId = UUID(uuidString: "5ea1ed00-0000-4000-8000-0000000000b1")!
    public static let letterId = UUID(uuidString: "1e77e400-0000-4000-8000-000000000073")!

    /// Fen Troll, pledged for today with a reminder at six.
    public static let samplePledge = Pledge(
        day: "2026-10-05", targetKind: .creature, targetId: sampleMonster.id, targetName: sampleMonster.name,
        icon: "troll", remindAt: "18:00", status: .pledged
    )

    public static let sampleLetter = Letter(
        id: letterId, text: "The heron was on the third post again. Say hello.", latitude: 51.4915, longitude: -0.0365,
        placeName: "The Crown", writtenAt: referenceDate, shownAt: nil
    )

    public static let sampleFoundLetter = FoundLetter(
        text: sampleLetter.text, writtenAt: referenceDate, placeName: "The Crown", line: "You wrote this here in January."
    )

    /// A sealed quest as the server sends it: the goal's place and name held back.
    public static func sealedQuest(minutes: Int, origin: Coordinate, activity: Activity = .ride, id: UUID = sealedQuestId, now: Date = Date()) -> Quest {
        let speed = activity.usualSpeedKmh
        let km = (speed * Double(minutes) / 60 * 10).rounded() / 10
        // As the server sends it: the place held back from the objective, the goal in the quest's `extra` for the phone to open.
        let goal: [String: JSONValue] = [
            "kind": .string("PLACE"), "name": .string("The Crown"), "title": .string("\(activity.verb) to The Crown"),
            "latitude": .number(51.4915), "longitude": .number(-0.0365), "category": .string("PUB"), "icon": .string("tavern"),
        ]
        let objective = Objective(
            id: id == sealedQuestId ? sealedObjectiveId : UUID(), objectiveType: .visitPOI, title: "Reach the goal",
            latitude: nil, longitude: nil, radiusMeters: 90, discoveryId: nil, required: true, order: 1,
            progress: ObjectiveProgress(current: 0, target: 1),
            extra: ["hidden": .bool(true)]
        )
        return Quest(
            id: id, questType: "SEALED", characterClass: .explorer, templateId: "SEALED",
            title: "Sealed quest (\(minutes) min)", description: "The board picked the way. Your goal opens halfway.",
            difficulty: minutes >= 90 ? .moderate : .easy, recommendedDistanceKm: km, estimatedDurationMinutes: minutes,
            baseXP: minutes >= 90 ? 250 : 150, status: .accepted, origin: origin, objectives: [objective],
            rewards: QuestRewards(xp: minutes >= 90 ? 250 : 150, ac: minutes >= 90 ? 80 : 40), acceptedAt: now, createdAt: now,
            activity: activity,
            extra: ["sealed": .bool(true), "minutes": .number(Double(minutes)),
                    "revealAtFraction": .number(SealedQuest.defaultRevealAtFraction), "goal": .object(goal)]
        )
    }
}
